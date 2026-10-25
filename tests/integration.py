"""Deterministic loopback API/CLI test with real Lean kernel proof checking.
Run after lake build: python3 tests/integration.py
"""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import copy
import hashlib
import json
import os
import signal
import shutil
import sys
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
XLB = ROOT / '.lake/build/bin/xlb'
XLC = ROOT / '.lake/build/bin/xlc'
EXPORT = json.loads((ROOT / 'fixtures/payment-audit.json').read_text())
TREE = json.loads((ROOT / 'fixtures/payment-audit-tree.json').read_text())


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def request(url, path, value=None, status=200):
    data = None if value is None else json.dumps(value).encode()
    req = urllib.request.Request(url + path, data=data,
                                headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=180) as response:
            code, body = response.status, response.read()
    except urllib.error.HTTPError as e:
        code, body = e.code, e.read()
    assert code == status, (path, code, body[:4000])
    return json.loads(body) if body else None


@contextmanager
def backend(directory, rpc=None, network=0, expected_exit=0, env=None, peer=None, peer_timeout=None,
            rpc_backoff_max=30, proof_jobs=None, extra_args=()):
    port = free_port()
    args = [str(XLB), '--data', str(directory), '--listen', f'127.0.0.1:{port}']
    args += list(extra_args)
    args += ['--rpc-backoff-max', str(rpc_backoff_max)]
    if proof_jobs is not None:
        args += ['--proof-jobs', str(proof_jobs)]
    if rpc:
        args += ['--rpc', rpc]
    if network:
        args += ['--network-id', str(network)]
    if peer:
        args += ['--peer', peer]
    if peer_timeout is not None:
        args += ['--peer-timeout', str(peer_timeout)]
    log = open(directory.parent / (directory.name + '.log'), 'w+')
    p = subprocess.Popen(args, cwd=ROOT, stdout=log, stderr=log,
                         env=None if env is None else {**os.environ, **env})
    url = f'http://127.0.0.1:{port}'
    try:
        for _ in range(100):
            if p.poll() is not None:
                log.seek(0)
                raise AssertionError(log.read())
            try:
                request(url, '/health')
                break
            except OSError:
                time.sleep(.1)
        else:
            raise AssertionError('backend did not start')
        yield url, p
    finally:
        if sys.exc_info()[0] is not None:
            saved = Path('/private/tmp') / f'xl-failure-{os.getpid()}'
            shutil.copytree(directory, saved, dirs_exist_ok=True)
            log.flush()
            shutil.copy2(log.name, str(saved) + '.log')
            print('Failure data saved at', saved, flush=True)
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
            try:
                p.wait(timeout=20)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
                raise AssertionError('backend did not stop gracefully')
        log.seek(0)
        output = log.read()
        log.close()
        assert p.returncode == expected_exit, (p.returncode, output)


def wait_job(url, id, expected, timeout=240):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = request(url, '/jobs/' + str(id))
        if result['status'] not in ('queued', 'running'):
            assert result['status'] == expected, result
            return result
        time.sleep(.2)
    raise AssertionError(f'job {id} timed out: {result}')


def queue(url, first=100, last=None, checks=('merkle', 'payments'), expected='succeeded', **extra):
    value = {'from': first, 'to': first if last is None else last, 'checks': checks, **extra}
    id = request(url, '/jobs', value, 202)['job_id']
    return wait_job(url, id, expected)


def cli(url, *args, success=True):
    p = subprocess.run([str(XLC), '--backend', url, *map(str, args)], cwd=ROOT,
                       capture_output=True, text=True, timeout=180)
    assert (p.returncode == 0) == success, (p.stdout, p.stderr)
    return json.loads(p.stdout) if success else p.stderr


def anchor():
    return dict(schema_version=1, stage='accepted', network_id=0, ledger_index=99,
                ledger_hash=EXPORT['parent_ledger_hash'], parent_ledger_hash='00' * 32,
                state_root=EXPORT['parent_state_root'], parent_state_root='00' * 32,
                pre_transaction_changes=[], transactions=[], post_transaction_changes=[])


def payment_subset_cases(folder):
    """Skipped Payments do not block supported proofs; supported failures still do."""
    partial = copy.deepcopy(EXPORT)
    unmodeled = partial['transactions'][2]
    unmodeled['result'] = unmodeled['metadata']['TransactionResult'] = 'tecUNFUNDED_PAYMENT'
    assert unmodeled['metadata_blob'].endswith('031080')
    unmodeled['metadata_blob'] = unmodeled['metadata_blob'][:-2] + '68'
    skipped_only = copy.deepcopy(partial)
    skipped_only['transactions'] = [copy.deepcopy(unmodeled)]
    skipped = skipped_only['transactions'][0]
    skipped['TransactionIndex'] = skipped['metadata']['TransactionIndex'] = 0
    assert skipped['metadata_blob'].startswith('201C00000002')
    skipped['metadata_blob'] = '201C00000000' + skipped['metadata_blob'][12:]
    all_skipped = copy.deepcopy(partial)
    for skipped in all_skipped['transactions'][:2]:
        skipped['result'] = skipped['metadata']['TransactionResult'] = 'tecUNFUNDED_PAYMENT'
        assert skipped['metadata_blob'].endswith('031000')
        skipped['metadata_blob'] = skipped['metadata_blob'][:-2] + '68'
    failed = copy.deepcopy(partial)
    tx = failed['transactions'][0]
    old_hash = tx['hash']
    assert '68400000000000000A' in tx['transaction_blob']
    tx['transaction_blob'] = tx['transaction_blob'].replace('68400000000000000A', '68400000000000000B')
    tx['transaction']['Fee'] = '11'
    new_hash = hashlib.sha512(b'TXN\0' + bytes.fromhex(tx['transaction_blob'])).digest()[:32].hex().upper()
    failed = json.loads(json.dumps(failed).replace(old_hash, new_hash))
    for name, payload, status, counts in [
        ('partial', partial, 'supported_checked', (2, 1, 0)),
        ('skipped', skipped_only, 'no_supported_payments', (0, 1, 0)),
        ('all-skipped', all_skipped, 'no_supported_payments', (0, 3, 0)),
        ('failed', failed, 'failed', (1, 1, 1)),
    ]:
        with backend(folder / name) as (url, _):
            request(url, '/ledgers', payload, 204)
            next_export = dict(schema_version=1, stage='accepted', network_id=0,
                ledger_index=101, ledger_hash='33' * 32,
                parent_ledger_hash=payload['ledger_hash'], parent_state_root=payload['state_root'],
                state_root=payload['state_root'], pre_transaction_changes=[], transactions=[], post_transaction_changes=[])
            request(url, '/ledgers', next_export, 204)
            result = queue(url, first=100, last=101, checks=['payments'],
                           expected='failed' if name == 'failed' else 'succeeded')
            attempt = result['verifications'][0]
            assert attempt['status'] == status, result
            report = json.loads(attempt['report_json'])
            assert (report['payments_verified'], report['payments_skipped'], report['payments_failed']) == counts, report
            assert report['payments_unsupported'] == report['payments_skipped']
            assert report['coverage'] == 'supported_payments_only'
            assert report['supported_proofs'] == 'kernel_checked'
            assert any(t['status'] == 'unsupported' and t['reason'] == 'failure result not modeled'
                       for t in report['transactions'])
            assert result['items'][1]['status'] == ('pending' if name == 'failed' else 'succeeded')
            assert next(r for r in request(url, '/ledgers') if r['ledger_index'] == '100')['trust'] == 'untrusted'
            if name != 'failed':
                assert len(result['verifications']) == 2
                assert all(p['kind'] == 'payments' for p in result['verifications'])
            if name in ('partial', 'all-skipped'):
                request(url, '/ledgers', anchor(), 204)
                cli(url, 'trust', 99, EXPORT['parent_ledger_hash'])
                state_file = folder / (name + '-state.json')
                state_file.write_text(json.dumps(TREE))
                cli(url, 'state', 'import', '--index', 99, '--hash', EXPORT['parent_ledger_hash'], '--file', state_file)
                queue(url, checks=['merkle'])
                row = next(r for r in request(url, '/ledgers') if r['ledger_index'] == '100')
                assert row['merkle'] == 'kernel_checked' and row['payments'] == status
                assert row['trust'] == 'verified_trusted', row
                with sqlite3.connect(folder / name / 'xl.sqlite3') as db:
                    assert db.execute('SELECT count(*) FROM trust_anchors').fetchone()[0] == 1
        if name in ('partial', 'all-skipped'):
            with backend(folder / name) as (url, _):
                assert next(r for r in request(url, '/ledgers') if r['ledger_index'] == '100')['trust'] == 'verified_trusted'


def main():
    with tempfile.TemporaryDirectory(prefix='xl-integration-') as tmp:
        folder = Path(tmp)
        data = folder / 'data'
        with backend(data) as (url, proc):
            assert cli(url, 'health')['service'] == 'XLB'
            # One backend owns the directory, including its verification worker.
            duplicate = subprocess.run([str(XLB), '--data', str(data)], cwd=ROOT,
                                       capture_output=True, text=True, timeout=10)
            assert duplicate.returncode == 1 and 'another XLB' in duplicate.stderr
            request(url, '/ledgers', EXPORT, 204)
            request(url, '/ledgers', EXPORT, 204)
            with sqlite3.connect(data / 'xl.sqlite3') as db:
                assert db.execute('SELECT count(*) FROM exports').fetchone()[0] == 1
                assert db.execute('SELECT count(*) FROM jobs').fetchone()[0] == 0
                assert db.execute('SELECT count(*) FROM trust_anchors').fetchone()[0] == 0
            blocked = queue(url, expected='blocked')
            assert blocked['verifications'][0]['status'] == 'blocked'
            # Payment-only checking needs no parent, state store, trust anchor or Merkle receipt.
            standalone = queue(url, checks=['payments'])
            assert [p['kind'] for p in standalone['verifications']] == ['payments']
            standalone_report = json.loads(standalone['verifications'][0]['report_json'])
            assert standalone_report['payments_verified'] == 3
            assert standalone_report['state_authentication'] == 'not_checked_by_payments'
            assert request(url, '/ledgers')[0]['trust'] == 'untrusted'
            with sqlite3.connect(data / 'xl.sqlite3') as db:
                assert db.execute('SELECT anchor_id,parent_verification_id FROM verifications WHERE job_id=?',
                                  (standalone['job_id'],)).fetchone() == (None, None)
                assert db.execute('SELECT count(*) FROM trust_anchors').fetchone()[0] == 0
                assert db.execute('SELECT count(*) FROM states').fetchone()[0] == 0
                assert db.execute("SELECT count(*) FROM verifications WHERE kind='merkle' AND status='kernel_checked'").fetchone()[0] == 0
                assert db.execute('PRAGMA foreign_key_check').fetchall() == []
            request(url, '/ledgers', anchor(), 204)
            # Trust alone does not imply state availability or a successful proof.
            cli(url, 'ledger', 'trust', '--index', 99, '--hash', EXPORT['parent_ledger_hash'], '--reason', "test's explicit starting point")
            queue(url, checks=['merkle'], expected='blocked')
            state_file = folder / 'state.json'
            state_file.write_text(json.dumps(TREE))
            cli(url, 'state', 'import', '--index', 99, '--hash', EXPORT['parent_ledger_hash'], '--file', state_file)
            queue(url, checks=['payments'])
            # Separate jobs in Payment-first order grant verified trust, not an anchor.
            queue(url, checks=['merkle'])
            assert next(r for r in request(url, '/ledgers') if r['ledger_index'] == '100')['trust'] == 'verified_trusted'
            assert all(r['trust'] == 'untrusted' for r in cli(url, 'ledgers', '-b', 'isolated'))
            with sqlite3.connect(data / 'xl.sqlite3') as db:
                assert db.execute('SELECT count(*) FROM trust_anchors').fetchone()[0] == 1
            submitted = cli(url, 'ledger', 'verify', '--index', 100, '--checks', 'merkle,payments')
            proof = wait_job(url, submitted['job_id'], 'succeeded')
            assert cli(url, 'job', 'show', '--id', submitted['job_id'])['status'] == 'succeeded'
            assert [p['kind'] for p in proof['verifications']] == ['merkle', 'payments']
            assert all(p['status'] == 'kernel_checked' for p in proof['verifications'])
            payment = json.loads(proof['verifications'][1]['report_json'])
            assert payment['payments_verified'] == 3 and payment['other_transactions'] == 1
            assert payment['full_ledger_semantics'] == 'not_proved'
            assert all(row['trust'] == 'verified_trusted' for row in cli(url, 'ledger', 'show') if row['ledger_index'] == '100')
            # Payment audits remain independent after a checked Merkle result exists.
            queue(url, checks=['payments'])
            queue(url, first=101, expected='blocked')
            # A next ledger can use the Merkle lineage without being marked operator trusted.
            next_export = dict(schema_version=1, stage='accepted', network_id=0,
                               ledger_index=101, ledger_hash='33' * 32,
                               parent_ledger_hash=EXPORT['ledger_hash'], parent_state_root=EXPORT['state_root'],
                               state_root=EXPORT['state_root'], pre_transaction_changes=[],
                               transactions=[], post_transaction_changes=[])
            request(url, '/ledgers', next_export, 204)
            lineage = queue(url, first=101, checks=['merkle'])
            assert lineage['verifications'][0]['status'] == 'kernel_checked'
            assert next(r for r in request(url, '/ledgers') if r['ledger_index'] == '101')['trust'] == 'untrusted'
            # Tree-first order also grants trust, including an empty Payment set.
            queue(url, first=101, checks=['payments'])
            assert next(r for r in request(url, '/ledgers') if r['ledger_index'] == '101')['trust'] == 'verified_trusted'
            fork = dict(next_export, ledger_hash='88' * 32)
            request(url, '/ledgers', fork, 204)
            queue(url, first=101, checks=['payments'], ledger_hash=fork['ledger_hash'])
            assert next(r for r in request(url, '/ledgers') if r['ledger_hash'] == fork['ledger_hash'].upper())['trust'] == 'untrusted'
            # Bad root is a failure, never promoted to kernel_checked.
            bad = dict(next_export, ledger_index=102, ledger_hash='44' * 32,
                       parent_ledger_hash=next_export['ledger_hash'], state_root='55' * 32)
            request(url, '/ledgers', bad, 204)
            failed_range = queue(url, first=102, last=103, checks=['merkle'], expected='failed')
            assert failed_range['verifications'][0]['status'] == 'failed'
            assert failed_range['items'][1]['status'] == 'pending'
            assert next(r for r in request(url, '/ledgers') if r['ledger_index'] == '102')['trust'] == 'untrusted'
            wrong_network = dict(EXPORT, network_id=1)
            request(url, '/ledgers', wrong_network, 422)
            # A supplied export ID disambiguates variants; default selection fails closed.
            variant = dict(EXPORT, close_time=EXPORT['close_time'] + 1)
            request(url, '/ledgers', variant, 204)
            request(url, '/jobs', {'from': 100, 'checks': ['payments']}, 422)
            original_id = proof['verifications'][0]['export_id']
            variant_id = next(r['export_id'] for r in request(url, '/exports')
                              if r['ledger_index'] == '100' and r['export_id'] != original_id)
            queue(url, checks=['payments'], export_id=int(variant_id))
            # Green checks from different payload variants cannot be combined.
            assert next(r for r in request(url, '/ledgers') if r['ledger_index'] == '100')['trust'] == 'untrusted'
            queue(url, checks=['payments'], export_id=int(original_id))
            assert next(r for r in request(url, '/ledgers') if r['ledger_index'] == '100')['trust'] == 'verified_trusted'
            # Tampering with a retained parent certificate blocks dependent verification.
            artifacts = json.loads(proof['verifications'][0]['artifacts_json'])
            certificate = next(Path(a['path']) for a in artifacts if a['path'].endswith('Certificate.lean'))
            certificate.write_text(certificate.read_text() + '\n-- altered after checking\n')
            queue(url, first=101, checks=['merkle'], ledger_hash=next_export['ledger_hash'], expected='blocked')
            assert next(r for r in request(url, '/ledgers') if r['ledger_hash'] == next_export['ledger_hash'].upper())['trust'] == 'untrusted'
            queue(url, checks=['payments'], export_id=int(original_id))
            # A storage failure must not acknowledge delivery.
            with sqlite3.connect(data / 'xl.sqlite3') as db:
                db.execute("CREATE TRIGGER reject_export BEFORE INSERT ON exports BEGIN SELECT RAISE(ABORT,'test storage failure'); END")
            storage_export = dict(next_export, ledger_index=108, ledger_hash='66' * 32)
            request(url, '/ledgers', storage_export, 503)
            with sqlite3.connect(data / 'xl.sqlite3') as db:
                assert db.execute('SELECT count(*) FROM exports e JOIN ledgers l ON e.ledger_id=l.id WHERE l.idx=108').fetchone()[0] == 0
                db.execute('DROP TRIGGER reject_export')
            request(url, '/ledgers', storage_export, 204)
            # Graceful shutdown interrupts actual proof subprocess work durably.
            interrupted = request(url, '/jobs', {'from': 100, 'checks': ['merkle'], 'export_id': int(original_id)}, 202)['job_id']
            for _ in range(200):
                running = request(url, '/jobs/' + interrupted)
                if running['verifications'] and running['verifications'][0]['attempt_dir']:
                    path = Path(running['verifications'][0]['attempt_dir'])
                    if (path / 'kernel.log').exists():
                        break
                time.sleep(.05)
            else:
                raise AssertionError('did not observe kernel checking')
            proc.send_signal(signal.SIGTERM)
            proc.wait(timeout=20)
            with sqlite3.connect(data / 'xl.sqlite3') as db:
                assert db.execute('SELECT status FROM jobs WHERE id=?', (interrupted,)).fetchone()[0] == 'interrupted'
                saved_jobs = db.execute('SELECT count(*) FROM jobs').fetchone()[0]
        with backend(data) as (url, _):
            assert len(cli(url, 'job', 'show')) == saved_jobs
            assert request(url, '/jobs/' + interrupted)['status'] == 'interrupted'
            assert any(row['trust'] == 'operator_trusted' for row in cli(url, 'ledger', 'show'))
        payment_subset_cases(folder)
        print('PASS API/CLI, durable receipt, manual jobs, trust isolation, real Merkle/Payment kernel proofs, lineage, gaps, failure, variants, tampering, storage failure, interrupted proof processes, restart')


if __name__ == '__main__':
    main()
