"""Read-only Lean source API: real receipts plus temporary corruption fixtures."""
from pathlib import Path
import hashlib
import json
import sqlite3
import tempfile

from integration import ROOT, EXPORT, TREE, anchor, backend, cli, queue, request


def read_source(url, endpoint, file_id):
    first = request(url, f'{endpoint}/{file_id}/0')
    chunks = [first['source']]
    assert len(first['source'].encode()) <= 65536
    for page in range(1, first['pages']):
        chunk = request(url, f'{endpoint}/{file_id}/{page}')
        assert chunk['page'] == page and chunk['pages'] == first['pages']
        assert len(chunk['source'].encode()) <= 65536
        chunks.append(chunk['source'])
    request(url, f"{endpoint}/{file_id}/{first['pages']}", status=422)
    return ''.join(chunks), first['recorded']


def main():
    with tempfile.TemporaryDirectory(prefix='xl-proof-source-') as tmp:
        folder = Path(tmp)
        data = folder / 'data'
        with backend(data) as (url, _):
            for kind, names in [('merkle', ['KernelMerkle', 'SHA512', 'SHA512Fast']),
                                ('payments', ['PaymentModel', 'LedgerProofs'])]:
                definition = request(url, f'/proofs/{kind}')
                assert [f['name'] for f in definition['files']] == [n + '.lean' for n in names]
                for f in definition['files']:
                    assert f['source'] == (ROOT / 'LeanXRPL' / f['name']).read_text()
            request(url, '/proofs/trust', status=422)
            request(url, '/ledgers', EXPORT, 204)
            payment = queue(url, checks=['payments'])
            request(url, '/ledgers', anchor(), 204)
            cli(url, 'trust', 99, EXPORT['parent_ledger_hash'])
            state_file = folder / 'state.json'
            state_file.write_text(json.dumps(TREE))
            cli(url, 'state', 'import', '--index', 99, '--hash', EXPORT['parent_ledger_hash'], '--file', state_file)
            merkle = queue(url, checks=['merkle'])
            for job in [payment, merkle]:
                attempt = job['verifications'][0]
                endpoint = f"/jobs/{job['job_id']}/verifications/{attempt['verification_id']}/proof"
                listing = request(url, endpoint)
                assert listing['kind'] == attempt['kind']
                assert listing['status'] == 'kernel_checked'
                assert listing['entry'] in [f['id'] for f in listing['files']]
                for f in listing['files']:
                    source, recorded = read_source(url, endpoint, f['id'])
                    assert recorded
                    paths = [a['path'] for a in json.loads(attempt['artifacts_json'])
                             if a['path'].endswith('/' + f['name'])]
                    assert len(paths) == 1 and source == Path(paths[0]).read_text()
                request(url, endpoint + '/generated_export/0', status=422)
                request(url, endpoint + '/../../export.json/0', status=404)
                request(url, endpoint.replace('/jobs/', '/bundles/other/jobs/'), status=422)
                wrong_job = merkle['job_id'] if job == payment else payment['job_id']
                request(url, endpoint.replace(f"/jobs/{job['job_id']}/", f'/jobs/{wrong_job}/'), status=422)
            attempt = payment['verifications'][0]
            endpoint = f"/jobs/{payment['job_id']}/verifications/{attempt['verification_id']}/proof"
            file = Path(attempt['attempt_dir']) / 'Payments.lean'
            original = file.read_bytes()
            # Detect modifications and missing historical files, retaining the entry.
            file.write_bytes(original + b'\n-- modified after checking\n')
            assert 'digest mismatch' in request(url, endpoint + '/generated_Payments/0', status=422)['error']
            file.unlink()
            assert request(url, endpoint)['entry'] == 'generated_Payments'
            assert 'missing' in request(url, endpoint + '/generated_Payments/0', status=422)['error']
            file.symlink_to(ROOT / 'LeanXRPL/PaymentModel.lean')
            request(url, endpoint + '/generated_Payments/0', status=422)
            file.unlink()
            file.write_bytes(original)
            # A changed recorded definition is never silently replaced by current source.
            records = json.loads(attempt['artifacts_json'])
            for record in records:
                if record['path'].endswith('/PaymentModel.lean'):
                    record['sha256'] = '00' * 32
            with sqlite3.connect(data / 'xl.sqlite3') as db:
                db.execute('UPDATE verifications SET artifacts_json=? WHERE id=?',
                           (json.dumps(records), attempt['verification_id']))
            request(url, endpoint + '/definition_PaymentModel/0', status=422)
            assert request(url, '/proofs/payments')['files'][0]['source']
            # Unchecked temporary source deliberately splits multibyte Lean symbols
            # across nominal 64 KiB boundaries, including a four-byte codepoint.
            unchecked = '-- ' + 'a' * 65531 + '∀🙂' * 24000 + '\n'
            file.write_text(unchecked)
            with sqlite3.connect(data / 'xl.sqlite3') as db:
                db.execute("UPDATE verifications SET artifacts_json='[]',status='interrupted' WHERE id=?",
                           (attempt['verification_id'],))
            source, recorded = read_source(url, endpoint, 'generated_Payments')
            assert source == unchecked and not recorded
            assert request(url, endpoint)['status'] == 'interrupted'
            # An unchecked folder symlink cannot make another folder browsable.
            sibling = folder / 'outside.lean'
            sibling.write_text('def privateFixture := 1\n')
            file.unlink()
            file.symlink_to(sibling)
            request(url, endpoint + '/generated_Payments/0', status=422)
            file.unlink()
            file.write_bytes(original)
            # No artifact path outside the allowlist is published.
            records.append({'path': str(sibling), 'sha256': hashlib.sha256(sibling.read_bytes()).hexdigest()})
            with sqlite3.connect(data / 'xl.sqlite3') as db:
                db.execute('UPDATE verifications SET artifacts_json=? WHERE id=?',
                           (json.dumps(records), attempt['verification_id']))
            assert 'outside.lean' not in json.dumps(request(url, endpoint))
        with backend(data, network=1) as (url, _):
            request(url, endpoint, status=422)
    print('PASS proof sources: real certificates, exact bytes, scoped IDs, receipt digests, missing/changed source, symlinks and UTF-8 paging')


if __name__ == '__main__':
    main()
