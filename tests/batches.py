"""Unsigned Batch API with actual Lean compilation and an independent XRPL codec.
All accounts use public fixtures; no real wallets, nodes, or application data.
"""
import copy
import hashlib
import json
import re
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
from integration import ROOT, backend, request

ACCOUNT = 'rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh'
KEY = '0330E7FC9D56BB25D6893BA3F317AE5BCF33B3291BD63DB32654A313222F7FD020'
SERVICE = 'rPT1Sjq2YGrBMTttX4GZHjKu9dyfzbpAYe'
DEST = 'rPEPPER7kfTD9w2To4CQk6UCfuHM9c6GDY'
FLAGS = ['--batch-service-address', SERVICE, '--batch-service-fee', '1000']


def candidate(count=1):
    return dict(account=ACCOUNT, public_key=KEY, sequence=100, service_sequence=108,
                last_ledger_sequence=200, network_fee_drops='100', payments=[
                    dict(destination=DEST, amount_drops=str(i+1), sequence=101+i)
                    for i in range(count)])


def wait(url, id):
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        result = request(url, '/batches/' + id)
        if result['status'] not in ('queued', 'running'):
            return result
        time.sleep(.1)
    raise AssertionError(result)


def main():
    with tempfile.TemporaryDirectory(prefix='xl-batches-') as tmp:
        data = Path(tmp) / 'data'
        with backend(data, extra_args=FLAGS) as (url, _):
            policy = request(url, '/batches/policy')
            assert policy['enabled'] and policy['policy']['service_address'] == SERVICE
            attempts = []
            for count in (1, 7):
                accepted = request(url, '/batches/prepare', candidate(count), 202)
                result = wait(url, accepted['attempt_id'])
                assert result['status'] == 'kernel_checked', result
                assert result['report']['bytes_binding'] == 'kernel_checked_serialization_equality'
                prepared = result['prepared']
                assert 'sorryAx' not in result['report']['axiom_audit']
                assert len(prepared['transaction']['RawTransactions']) == count + 1
                oracle = subprocess.run(['node', '--input-type=module', '-e', '''
import { encode, encodeForSigning } from 'xrpl';
let text=''; for await (const chunk of process.stdin) text+=chunk;
const tx=JSON.parse(text);
console.log(JSON.stringify({raw:encode(tx),signing:encodeForSigning(tx)}));
'''], input=json.dumps(prepared['transaction']), cwd=ROOT/'frontend', text=True,
                    capture_output=True, check=True)
                independently = json.loads(oracle.stdout)
                assert independently['raw'] == prepared['unsigned_bytes']
                expected = hashlib.sha512(bytes.fromhex(independently['signing'])).digest()[:32].hex().upper()
                assert expected == prepared['signing_digest']
                cert = request(url, f"/batches/{result['attempt_id']}/artifacts/Certificate.lean")
                assert hashlib.sha256(cert['content'].encode()).hexdigest().upper() == cert['sha256']
                # Alter the bytes while preserving the original inputs and policy:
                # the actual kernel must reject the generated theorem.
                broken = cert['content'].replace('def raw : List Nat := [18,0,71', 'def raw : List Nat := [18,0,70')
                assert broken != cert['content']
                bad = Path(tmp)/'Tampered.lean'
                bad.write_text(broken)
                checked = subprocess.run(['lake','env','lean',str(bad)],cwd=ROOT,capture_output=True,text=True,timeout=60)
                assert checked.returncode != 0, checked.stdout
                if count==1:
                    # The kernel also rejects an invalid policy even when the
                    # raw bytes are regenerated to match it (not merely a hash mismatch).
                    invalid_policy = cert['content'].replace(',1000⟩\n',',0⟩\n',1)
                    invalid_policy = re.sub(r'def raw : List Nat := \[[0-9,]*\]',
                                            'def raw : List Nat := serialize policy batch',invalid_policy)
                    bad.write_text(invalid_policy)
                    checked = subprocess.run(['lake','env','lean',str(bad)],cwd=ROOT,capture_output=True,text=True,timeout=60)
                    assert checked.returncode!=0,checked.stdout
                folder = data/'batch-attempts'/result['attempt_id']
                recheck = subprocess.run(['python3','tools/verify_batch_certificate.py',str(folder)],
                                         cwd=ROOT,capture_output=True,text=True,timeout=120)
                assert recheck.returncode==0, recheck.stderr
                original = (folder/'unsigned.hex').read_text()
                (folder/'unsigned.hex').write_text('00'+original[2:])
                tampered = subprocess.run(['python3','tools/verify_batch_certificate.py',str(folder)],
                                          cwd=ROOT,capture_output=True,text=True,timeout=120)
                assert tampered.returncode!=0 and 'digest mismatch' in tampered.stderr
                (folder/'unsigned.hex').write_text(original)
                if count==1:
                    # Rehashing an altered JSON export must not make it appear
                    # certified: the Lean reconstruction checks the relationship.
                    original_tx = (folder/'transaction.json').read_text()
                    original_manifest = (folder/'manifest.json').read_text()
                    (folder/'transaction.json').write_text('{}')
                    forged = json.loads(original_manifest)
                    for entry in forged:
                        if entry['name']=='transaction.json':
                            entry['sha256']=hashlib.sha256(b'{}').hexdigest().upper()
                    (folder/'manifest.json').write_text(json.dumps(forged))
                    check = subprocess.run(['python3','tools/verify_batch_certificate.py',str(folder)],
                                           cwd=ROOT,capture_output=True,text=True,timeout=120)
                    assert check.returncode!=0 and 'Lean export binding failed' in check.stderr, check.stderr
                    (folder/'transaction.json').write_text(original_tx)
                    (folder/'manifest.json').write_text(original_manifest)
                attempts.append(result)
            duplicate = request(url, '/batches/prepare', candidate(), 202)
            assert duplicate['attempt_id'] != attempts[0]['attempt_id']
            assert wait(url, duplicate['attempt_id'])['status'] == 'kernel_checked'
            invalids = [dict(Flags=0), dict(payments=[]), dict(public_key='02'+'FF'*32),
                        dict(account=DEST), dict(sequence=0), dict(service_sequence=101),
                        dict(network_fee_drops='0'), dict(network_fee_drops='01'),
                        dict(network_fee_drops=1), dict(service_fee_drops='1'),
                        dict(Fee='1'), dict(Signers=[]), dict(payments=candidate(7)['payments']+[candidate()['payments'][0]])]
            for changes in invalids:
                value = dict(candidate(), **changes)
                request(url, '/batches/prepare', value, 422)
            for changes in [dict(destination=SERVICE), dict(amount_drops='0'), dict(amount_drops='1.1'),
                            dict(amount_drops={'currency':'USD'}), dict(sequence=100), dict(sequence=2**32),
                            dict(Account=DEST), dict(Flags=0x20000), dict(Paths=[]), dict(TxnSignature='00')]:
                value = candidate()
                value['payments'][0].update(changes)
                request(url, '/batches/prepare', value, 422)
            request(url, '/batches/1/artifacts/unknown', status=422)
            request(url, '/batches/1/artifacts/%2e%2e', status=422)
            assert request(url, '/batches/1')['status'] == 'kernel_checked'
        # Startup retains completed attempts, and marks any unfinished work interrupted.
        with sqlite3.connect(data/'xl.sqlite3') as db:
            db.execute("INSERT INTO batch_attempts(network,request_json,prepared_json,status) VALUES(0,'{}','{}','queued')")
            interrupted_id = str(db.execute('SELECT last_insert_rowid()').fetchone()[0])
        partial = data/'batch-attempts'/interrupted_id
        partial.mkdir()
        (partial/'kernel.log').write_text('interrupted compilation diagnostics\n')
        with backend(data, extra_args=FLAGS) as (url, _):
            assert request(url, '/batches/1')['status'] == 'kernel_checked'
            assert request(url, '/batches/'+interrupted_id)['status'] == 'interrupted'
            assert request(url, '/batches/'+interrupted_id)['report']['artifacts']==['kernel.log']
        with backend(Path(tmp)/'disabled') as (url, _):
            assert not request(url, '/batches/policy')['enabled']
            request(url, '/batches/prepare', candidate(), 422)
        with backend(Path(tmp)/'network', network=1025, extra_args=FLAGS) as (url, _):
            result = wait(url, request(url, '/batches/prepare', candidate(), 202)['attempt_id'])
            assert result['status'] == 'kernel_checked', result
            assert result['prepared']['transaction']['NetworkID'] == 1025
        # A project with a deliberately missing proof module must retain a failed
        # attempt and diagnostics; it must never synthesize certificate success.
        project = Path(tmp)/'broken-project'
        (project/'tools').mkdir(parents=True)
        (project/'tools/generate_merkle_certificate.py').write_text('# startup marker\n')
        (project/'lean-toolchain').write_text((ROOT/'lean-toolchain').read_text())
        (project/'lakefile.lean').write_text('import Lake\nopen Lake DSL\npackage broken\n')
        (project/'LeanXRPL').mkdir()
        (project/'LeanXRPL/BatchPolicy.lean').write_text('import MissingModule\n')
        broken_module = project/'.lake/build/lib/lean/LeanXRPL/BatchPolicy.olean'
        broken_module.parent.mkdir(parents=True)
        broken_module.write_bytes(b'deliberately invalid compiled module')
        with backend(Path(tmp)/'failure', extra_args=FLAGS+['--project-root',str(project)]) as (url, _):
            result = wait(url,request(url,'/batches/prepare',candidate(),202)['attempt_id'])
            assert result['status']=='failed' and 'compilation failed' in result['error'], result
            assert request(url,f"/batches/{result['attempt_id']}/artifacts/kernel.log")['content']
            assert 'manifest.json' not in result['report']['artifacts']
    print('PASS Batch certificates, real kernel rejection, independent codec/digest, strict policy, attempts, restart, and disabled configuration')


if __name__ == '__main__':
    main()
