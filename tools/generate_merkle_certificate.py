"""Generate a self-contained pure Lean certificate for an exported root replay.

The generator and SQLite contents are untrusted. Generated edit proofs and
SHA-512Half equalities are checked by Lean's kernel. No native_decide is emitted.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
PREFIX = 'LedgerCertificate'
NS = 'LedgerCertificate'
ZERO = bytes(32)
HEADER = 'set_option maxRecDepth 100000\nset_option maxHeartbeats 0\nopen LeanXRPL.KernelMerkle\n'


def num(value):
    return '0x' + value.hex() if isinstance(value, bytes) else str(value)


def values(data):
    return '[' + ','.join(map(str, data)) + ']'


def named(h):
    return h.hex()


def tree_ref(h, known):
    if h == ZERO:
        return 'Tree.empty'
    return f'tree_{named(h)}' if h in known else f'(Tree.opaque {num(h)})'


def root_ref(h, known):
    if h == ZERO:
        return 'Rooted.empty'
    return f'root_{named(h)}' if h in known else f'(Rooted.opaque {num(h)})'


def forest(proofs):
    result = 'ForestRooted.nil'
    for proof in reversed(proofs):
        result = f'(ForestRooted.cons {proof} {result})'
    return result


def descriptor(wire):
    if wire[-1] == 1:
        return ('leaf', wire[-33:-1], wire[:-33])
    if wire[-1] == 2:
        assert len(wire) == 513
        return ('inner', tuple(wire[i * 32:i * 32 + 32] for i in range(16)))
    assert wire[-1] == 3 and (len(wire) - 1) % 33 == 0
    children = [ZERO] * 16
    for i in range(0, len(wire) - 1, 33):
        children[wire[i + 32]] = wire[i:i + 32]
    return ('inner', tuple(children))


def image(value):
    return 'none' if value is None else '(some ' + values(bytes.fromhex(value['blob'])) + ')'


def generate(export_file, database, report, destination):
    export = json.loads(Path(export_file).read_text())
    global PREFIX, NS
    index = export['ledger_index']
    PREFIX = NS = f'Ledger{index}'
    transactions = sorted(export['transactions'], key=lambda t: t['TransactionIndex'])
    assert [t['TransactionIndex'] for t in transactions] == list(range(len(transactions)))
    changes = (export['pre_transaction_changes'] + [c for t in transactions for c in t['changes']] +
               export['post_transaction_changes'])
    summary = [json.loads(line) for line in Path(report).read_text().splitlines()][-1]
    trace = summary['root_transitions']
    assert summary['merkle_replay'] == 'verified' and len(changes) == len(trace)
    assert summary['parent_root'] == export['parent_state_root'].upper()
    assert summary['computed_root'] == export['state_root'].upper()
    roots = [bytes.fromhex(export['parent_state_root'])]
    for change, step in zip(changes, trace):
        assert step['before_root'] == roots[-1].hex().upper() and step['key'] == change['key'].upper()
        roots.append(bytes.fromhex(step['after_root']))
    with sqlite3.connect(Path(database).resolve().as_uri() + '?mode=ro', uri=True) as db:
        nodes = {h: descriptor(w) for h, w in db.execute('SELECT hash,wire FROM nodes')}

    ordered = []
    visiting, visited = set(), set()
    def walk(h):
        if h == ZERO or h not in nodes or h in visited:
            return
        assert h not in visiting, 'cyclic witness'
        visiting.add(h)
        node = nodes[h]
        if node[0] == 'inner':
            for child in node[1]:
                walk(child)
        visiting.remove(h)
        visited.add(h)
        ordered.append(h)
    for h in roots:
        assert h == ZERO or h in nodes
        walk(h)
    all_nodes = set(ordered)
    # Only the initial and final commitments require cryptographic proofs.
    endpoint_order = []
    endpoint_seen = set()
    def endpoint(h):
        if h == ZERO or h not in all_nodes or h in endpoint_seen:
            return
        endpoint_seen.add(h)
        node = nodes[h]
        if node[0] == 'inner':
            for child in node[1]:
                endpoint(child)
        endpoint_order.append(h)
    endpoint(roots[0]); endpoint(roots[-1])
    destination = Path(destination).resolve()
    folder = destination / PREFIX
    folder.mkdir(parents=True, exist_ok=True)

    def write(module, contents):
        path = folder / (module + '.lean')
        if not path.exists() or path.read_text() != contents:
            path.write_text(contents)
        return PREFIX + '.' + module

    tree_modules = []
    for start in range(0, max(1, len(ordered)), 300):
        module = f'Trees{start // 300:03d}'
        previous = tree_modules[-1] if tree_modules else 'LeanXRPL.KernelMerkle'
        text = f'import {previous}\n{HEADER}\nnamespace {NS}\n'
        for h in ordered[start:start + 300]:
            node = nodes[h]
            if node[0] == 'leaf':
                text += f'def data_{named(h)} : List Nat := {values(node[2])}\n'
                term = f'Tree.leaf {num(node[1])} data_{named(h)}'
            else:
                term = 'Tree.inner [' + ','.join(tree_ref(c, all_nodes) for c in node[1]) + ']'
            text += f'def tree_{named(h)} : Tree := {term}\n'
        text += f'end {NS}\n'
        tree_modules.append(write(module, text))

    hash_modules = []
    for start in range(0, len(endpoint_order), 32):
        module = f'Hashes{start // 32:03d}'
        text = f'import LeanXRPL.KernelMerkle\nimport LeanXRPL.SHA512Fast\n{HEADER}\nnamespace {NS}\n'
        for h in endpoint_order[start:start + 32]:
            node = nodes[h]
            if node[0] == 'leaf':
                term = f'Node.leaf {num(node[1])} {values(node[2])}'
            else:
                term = 'Node.inner [' + ','.join(num(c) for c in node[1]) + ']'
            text += f'def node_{named(h)} : Node := {term}\n'
            text += (f'theorem hash_{named(h)} : nodeHash node_{named(h)} = {num(h)} := '
                     f'(LeanXRPL.SHA512Fast.half_eq (payload node_{named(h)})).symm.trans '
                     f'(by decide +kernel : LeanXRPL.SHA512Fast.half (payload node_{named(h)}) = {num(h)})\n')
        text += f'end {NS}\n'
        hash_modules.append(write(module, text))

    step_modules = []
    for start in range(0, max(1, len(changes)), 32):
        module = f'Steps{start // 32:03d}'
        previous = step_modules[-1] if step_modules else tree_modules[-1]
        text = f'import {previous}\n{HEADER}\nnamespace {NS}\n'
        indices = list(range(start, min(start + 32, len(changes))))
        for i in indices:
            c = changes[i]
            text += (f'def change_{i:04d} : Change := ⟨{num(bytes.fromhex(c["key"]))},'
                     f'{image(c["before"])},{image(c["after"])}⟩\n')
            text += (f'theorem step_{i:04d} : apply {tree_ref(roots[i], all_nodes)} change_{i:04d} = '
                     f'some {tree_ref(roots[i+1], all_nodes)} := by rfl\n')
        group = start // 32
        text += f'def changes_{group:03d} : List Change := [' + ','.join(f'change_{i:04d}' for i in indices) + ']\n'
        proof = f'(Execution.nil {tree_ref(roots[indices[-1]+1] if indices else roots[0], all_nodes)})'
        for i in reversed(indices):
            proof = f'(Execution.cons step_{i:04d} {proof})'
        text += (f'theorem execution_{group:03d} : Execution {tree_ref(roots[start], all_nodes)} '
                 f'changes_{group:03d} {tree_ref(roots[indices[-1]+1] if indices else roots[0], all_nodes)} := {proof}\nend {NS}\n')
        step_modules.append(write(module, text))

    root_modules = []
    # These depend on the independently checked hash lemmas and tree definitions.
    hash_index = {h: hash_modules[i // 32] for i, h in enumerate(endpoint_order)}
    for start in range(0, max(1, len(endpoint_order)), 300):
        module = f'Roots{start // 300:03d}'
        imports = {tree_modules[-1]} | {hash_index[h] for h in endpoint_order[start:start + 300]}
        if root_modules:
            imports.add(root_modules[-1])
        text = ''.join(f'import {m}\n' for m in sorted(imports)) + HEADER + f'\nnamespace {NS}\n'
        for h in endpoint_order[start:start + 300]:
            node = nodes[h]
            if node[0] == 'leaf':
                proof = f'Rooted.leaf hash_{named(h)}'
            else:
                proof = ('Rooted.inner (by rfl) ' + forest([root_ref(c, endpoint_seen) for c in node[1]]) +
                         f' hash_{named(h)}')
            text += f'theorem root_{named(h)} : Rooted {num(h)} tree_{named(h)} := {proof}\n'
        text += f'end {NS}\n'
        root_modules.append(write(module, text))

    text = f'import {step_modules[-1]}\nimport {root_modules[-1]}\n{HEADER}\nnamespace {NS}\n'
    groups = list(range(len(step_modules)))
    change_groups = f'changes_{groups[-1]:03d}'
    for i in reversed(groups[:-1]):
        change_groups = f'(changes_{i:03d} ++ {change_groups})'
    text += 'def exportedChanges : List Change := ' + change_groups + '\n'
    execution = f'execution_{groups[-1]:03d}'
    for i in reversed(groups[:-1]):
        execution = f'(Execution.append execution_{i:03d} {execution})'
    text += (f'theorem all_changes_execute : Execution {tree_ref(roots[0], all_nodes)} exportedChanges '
             f'{tree_ref(roots[-1], all_nodes)} := {execution}\n')
    text += f'theorem change_count : exportedChanges.length = {len(changes)} := by decide +kernel\n'
    text += (f'theorem ledger_{index-1}_to_{index} : LedgerTransition {num(roots[0])} '
             f'{num(roots[-1])} exportedChanges :=\n'
             f'  certify {root_ref(roots[0], endpoint_seen)} all_changes_execute {root_ref(roots[-1], endpoint_seen)}\n'
             f'theorem full_ledger_certificate : exportedChanges.length = {len(changes)} ∧\n'
             f'    LedgerTransition {num(roots[0])} {num(roots[-1])} exportedChanges :=\n'
             f'  ⟨change_count, ledger_{index-1}_to_{index}⟩\n'
             f'end {NS}\n#print axioms {NS}.full_ledger_certificate\n')
    final_module = write('Certificate', text)
    manifest = dict(namespace=NS, export=str(Path(export_file).resolve()), export_sha256=hashlib.sha256(Path(export_file).read_bytes()).hexdigest(),
                    changes=len(changes), parent_root=roots[0].hex().upper(), final_root=roots[-1].hex().upper(),
                    tree_nodes=len(ordered), authenticated_endpoint_nodes=len(endpoint_order),
                    trees=tree_modules, hashes=hash_modules, steps=step_modules, roots=root_modules, final=final_module)
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({k: manifest[k] for k in ('changes', 'tree_nodes', 'authenticated_endpoint_nodes') }), flush=True)
    return destination, manifest


def build(destination, manifest, jobs, recheck=False):
    env = os.environ.copy()
    env['LEAN_PATH'] = str(destination) + os.pathsep + str(ROOT / '.lake/build/lib/lean')
    completed = 0
    total = sum(len(manifest[k]) for k in ('trees', 'hashes', 'steps', 'roots')) + 1
    def compile_module(module):
        nonlocal completed
        source = destination / (module.replace('.', '/') + '.lean')
        output = source.with_suffix('.olean')
        log = source.with_suffix('.log')
        if not recheck and output.exists() and output.stat().st_mtime >= source.stat().st_mtime:
            return module
        started = time.monotonic()
        for attempt in range(3):
            result = subprocess.run(['lake', 'env', 'lean', '-R', str(destination), '-j', '1', '-o', str(output), str(source)],
                                    cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if result.returncode == 0 or 'failed to create file' not in result.stdout:
                break
        log.write_text(result.stdout)
        if result.returncode:
            raise RuntimeError(f'{module}: {result.stdout[:6000]}')
        completed += 1
        print(f'kernel_checked={completed}/{total} module={module} seconds={time.monotonic()-started:.2f}', flush=True)
        return module
    # Trees and step groups each form a dependency chain. Hash groups are independent.
    with ThreadPoolExecutor(max_workers=jobs) as workers:
        hashes = [workers.submit(compile_module, m) for m in manifest['hashes']]
        for m in manifest['trees']:
            compile_module(m)
        for m in manifest['steps']:
            compile_module(m)
        for result in as_completed(hashes):
            result.result()
    for m in manifest['roots']:
        compile_module(m)
    compile_module(manifest['final'])
    result = dict(status='kernel_checked', changes=manifest['changes'], parent_root=manifest['parent_root'],
                  expected_root=manifest['final_root'], theorem=manifest.get('namespace', NS) + '.full_ledger_certificate',
                  hash_definition='pure Lean SHA-512Half', native_decide=False,
                  hash_evaluator='SHA512Fast via half_eq', hash_workers=jobs,
                  axiom_audit=(destination / (manifest['final'].replace('.', '/') + '.log')).read_text())
    (destination / 'kernel-verification.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('export')
    parser.add_argument('database')
    parser.add_argument('replay_report')
    parser.add_argument('destination')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--recheck', action='store_true', help='recompile every generated proof instead of reusing checked modules')
    parser.add_argument('--jobs', type=int, default=6)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 64:
        parser.error('--jobs must be 1 to 64')
    destination, manifest = generate(args.export, args.database, args.replay_report, args.destination)
    if args.check:
        build(destination, manifest, args.jobs, args.recheck)
