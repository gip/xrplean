"""Independently compare generated Lean change literals with the source export."""
import argparse
import hashlib
import json
from pathlib import Path
import re


IMAGE = r'(none|\(some \[[0-9,]*\]\))'
DECL = re.compile(r'def change_(\d+) : Change := ⟨(0x[0-9a-f]+),' + IMAGE + ',' + IMAGE + r'⟩')


def image(text):
    if text == 'none':
        return None
    digits = text[len('(some ['):-len('])')]
    return bytes(map(int, digits.split(','))) if digits else b''


def verify(export_file, certificate_directory):
    export_file, directory = Path(export_file), Path(certificate_directory)
    export = json.loads(export_file.read_text())
    manifest = json.loads((directory / 'manifest.json').read_text())
    original = (export['pre_transaction_changes'] +
                [c for t in sorted(export['transactions'], key=lambda t: t['TransactionIndex']) for c in t['changes']] +
                export['post_transaction_changes'])
    extracted = []
    for module in manifest['steps']:
        source = (directory / (module.replace('.', '/') + '.lean')).read_text()
        declarations = DECL.findall(source)
        groups = re.findall(r'def changes_(\d+) : List Change := \[([^\]]*)\]', source)
        assert len(groups) == 1
        identifiers = [int(i) for i in re.findall(r'change_(\d+)', groups[0][1])]
        assert identifiers == [int(row[0]) for row in declarations], 'group reorders or omits declared changes'
        for index, key, before, after in declarations:
            extracted.append((int(index), int(key, 16), image(before), image(after)))
    final_source = (directory / (manifest['final'].replace('.', '/') + '.lean')).read_text()
    line = next(line for line in final_source.splitlines() if line.startswith('def exportedChanges'))
    assert [int(i) for i in re.findall(r'changes_(\d+)', line)] == list(range(len(manifest['steps'])))
    roots = re.search(r'theorem ledger_\d+_to_\d+ : LedgerTransition (0x[0-9a-f]+) (0x[0-9a-f]+)', final_source)
    assert roots is not None
    assert [int(h, 16) for h in roots.groups()] == [int(export['parent_state_root'], 16), int(export['state_root'], 16)]
    assert [row[0] for row in extracted] == list(range(len(original)))
    for (_, key, before, after), change in zip(extracted, original):
        expected_before = None if change['before'] is None else bytes.fromhex(change['before']['blob'])
        expected_after = None if change['after'] is None else bytes.fromhex(change['after']['blob'])
        assert (key, before, after) == (int(change['key'], 16), expected_before, expected_after)
    checksum = hashlib.sha256(export_file.read_bytes()).hexdigest()
    assert manifest['export_sha256'] == checksum
    assert manifest['parent_root'] == export['parent_state_root'].upper()
    assert manifest['final_root'] == export['state_root'].upper()
    return dict(status='verified', changes=len(original), exact_keys_and_before_after_bytes=True,
                execution_order_matches_export=True,
                export_sha256=checksum, binding='independent JSON-to-Lean-literal comparison')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('export')
    parser.add_argument('certificate_directory')
    args = parser.parse_args()
    print(json.dumps(verify(args.export, args.certificate_directory), indent=2))
