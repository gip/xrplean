"""Sparse proof witnesses, collapse edges, and parallel SHA512Fast kernel certificates.

All ledgers/stores are synthetic and temporary. Expected roots come from the
independent Python SHAMap builder also used by acquisition tests.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile

from incremental import make_tree
from integration import ROOT, backend, queue, request

ZERO = '00' * 32


def key(prefix):
    return bytes.fromhex(prefix.ljust(64, '0'))


def value(n):
    return n.to_bytes(12, 'big')


def tree(entries):
    return make_tree(entries) if entries else (ZERO, [])


def envelope(index, ledger_hash, parent_hash, root, parent_root, changes=()):
    return dict(schema_version=1, stage='accepted', network_id=0,
                ledger_index=index, ledger_hash=ledger_hash,
                parent_ledger_hash=parent_hash, state_root=root, parent_state_root=parent_root,
                pre_transaction_changes=list(changes), transactions=[], post_transaction_changes=[])


def run_case(url, name, index, initial, edits, expected_nodes=None, workers=6):
    parent_root, records = tree(initial)
    entries = dict(initial)
    changes = []
    for object_key, after in edits:
        before = entries.get(object_key)
        changes.append(dict(key=object_key.hex(),
                            operation='delete' if after is None else 'insert' if before is None else 'modify',
                            before=None if before is None else dict(blob=before.hex()),
                            after=None if after is None else dict(blob=after.hex())))
        if after is None:
            del entries[object_key]
        else:
            entries[object_key] = after
    final_root, _ = tree(entries)
    parent_hash = hashlib.sha256((name + '-parent').encode()).hexdigest()
    ledger_hash = hashlib.sha256(name.encode()).hexdigest()
    request(url, '/ledgers', envelope(index-1, parent_hash, ZERO, parent_root, ZERO), 204)
    if records:
        request(url, '/state', dict(ledger_index=index-1, ledger_hash=parent_hash,
                                   nodes=[dict(hash=h.hex(), wire=w.hex()) for _, w, h in records]), 201)
    request(url, '/trust', dict(ledger_index=index-1, ledger_hash=parent_hash, reason='synthetic witness test'))
    request(url, '/ledgers', envelope(index, ledger_hash, parent_hash, final_root, parent_root, changes), 204)
    result = queue(url, first=index, checks=['merkle'])
    attempt = result['verifications'][0]
    assert attempt['status'] == 'kernel_checked', result
    directory = Path(attempt['attempt_dir'])
    manifest = json.loads((directory / 'certificate/manifest.json').read_text())
    receipt = json.loads((directory / 'certificate/kernel-verification.json').read_text())
    assert receipt['hash_workers'] == workers and receipt['hash_evaluator'] == 'SHA512Fast via half_eq', receipt
    assert receipt['native_decide'] is False
    assert manifest['changes'] == len(edits)
    assert manifest['parent_root'] == parent_root and manifest['final_root'] == final_root
    assert 'sorryAx' not in receipt['axiom_audit'] and 'Lean.ofReduceBool' not in receipt['axiom_audit']
    for group in re.findall(r'depends on axioms:\s*\[([^\]]*)\]', receipt['axiom_audit']):
        assert {a.strip() for a in group.split(',')} <= {'propext', 'Classical.choice', 'Quot.sound'}
    assert json.loads((directory / 'binding.log').read_text())['status'] == 'verified'
    artifacts = json.loads(attempt['artifacts_json'])
    assert any(a['path'].endswith('/SHA512Fast.lean') for a in artifacts)
    assert any(a['path'].endswith('/SHA512Fast.olean') for a in artifacts)
    if expected_nodes is not None:
        assert manifest['authenticated_endpoint_nodes'] == expected_nodes, manifest
    print(json.dumps(dict(case=name, changes=len(edits), snapshot_nodes=len(records),
                          endpoint_nodes=manifest['authenticated_endpoint_nodes'],
                          hash_batches=len(manifest['hashes']), workers=workers)), flush=True)
    return directory, manifest


def reject_bad_certificate(directory, folder):
    cert = directory / 'certificate'
    manifest = json.loads((cert / 'manifest.json').read_text())
    source = (cert / (manifest['hashes'][0].replace('.', '/') + '.lean')).read_text()
    # Keep the same input and corrupt the claimed digest in both the outer goal
    # and optimized subgoal. Kernel evaluation must reject the false fact.
    source, count = re.subn(r'(= )0x[0-9a-f]+', r'\g<1>0', source, count=2)
    assert count == 2
    bad = folder / 'BadHash.lean'
    bad.write_text(source)
    env = dict(os.environ, LEAN_PATH=str(cert) + os.pathsep + str(ROOT / '.lake/build/lib/lean'))
    result = subprocess.run(['lake', 'env', 'lean', str(bad)], cwd=ROOT, env=env,
                            capture_output=True, text=True, timeout=120)
    assert result.returncode != 0 and 'decide' in result.stdout, (result.stdout, result.stderr)

    # Removing collapse evidence must not become an accepted proof. Use a fresh
    # generator destination and a copy of the portable synthetic witness.
    copied = folder / 'missing.sqlite3'
    with sqlite3.connect(directory / 'witness.sqlite3') as db:
        with sqlite3.connect(copied) as target:
            db.backup(target)
    with sqlite3.connect(copied) as db:
        leaf = db.execute('SELECT hash FROM nodes WHERE substr(wire,-1)=? LIMIT 1', (b'\x01',)).fetchone()
        assert leaf
        db.execute('DELETE FROM nodes WHERE hash=?', leaf)
    result = subprocess.run([sys.executable, '-I', str(ROOT / 'tools/generate_merkle_certificate.py'),
                             str(directory / 'export.json'), str(copied), str(directory / 'replay.jsonl'),
                             str(folder / 'missing-certificate'), '--check', '--jobs', '6'],
                            cwd=ROOT, capture_output=True, text=True, timeout=120)
    assert result.returncode != 0, 'missing edit/collapse witness accepted'


def main():
    dense = {key(f'{i:02x}'): value(i+1) for i in range(256)}
    # A long shared path followed by two leaves exercises cascading collapse.
    nested = {key('0'): value(1), key('a12340'): value(2), key('a12341'): value(3)}
    # Deleting b0 leaves a branching b1 subtree: its root must be opened, but
    # its unchanged leaf children can remain opaque. A later edit opens those.
    branching = {key('0'): value(1), key('b0'): value(2), key('b10'): value(3), key('b11'): value(4)}
    with tempfile.TemporaryDirectory(prefix='xl-witness-') as tmp:
        folder = Path(tmp)
        with backend(folder / 'data') as (url, _):
            single, _ = run_case(url, 'dense-update', 1000, dense, [(key('00'), value(999))], expected_nodes=6)
            _, many = run_case(url, 'parallel-batches', 1002, dense,
                               [(k, value(1000+i)) for i, k in enumerate(list(dense)[:40])])
            assert len(many['hashes']) >= 2
            run_case(url, 'insert-update-delete-reinsert', 1004, dense,
                     [(key('001'), value(8)), (key('001'), value(9)), (key('01'), None),
                      (key('001'), None), (key('01'), value(10))])
            collapsed, _ = run_case(url, 'nested-collapse', 1006, nested, [(key('a12340'), None)])
            run_case(url, 'branching-survivor', 1008, branching, [(key('b0'), None)])
            run_case(url, 'branching-then-collapse', 1010, branching,
                     [(key('b0'), None), (key('b10'), None)])
            run_case(url, 'empty-roundtrip', 1012, {},
                     [(key('e'), value(1)), (key('e'), None)], expected_nodes=0)
            run_case(url, 'unchanged-root', 1014, dense, [], expected_nodes=1)
            run_case(url, 'delete-final-leaf', 1016, {key('e'): value(1)}, [(key('e'), None)], expected_nodes=2)
            reject_bad_certificate(collapsed, folder)
        with backend(folder / 'one-worker', proof_jobs=1) as (url, _):
            run_case(url, 'one-worker', 2000, dense, [(key('00'), value(999))], expected_nodes=6, workers=1)
    print('PASS sparse witnesses, dense/update/insert/delete/empty/collapse cases, multi-batch six-worker and single-worker kernel certificates, exact binding, axiom audits, and false/missing-witness rejection')


if __name__ == '__main__':
    main()
