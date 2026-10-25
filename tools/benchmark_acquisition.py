"""Compare fresh XL peer/RPC snapshots of one exact ledger on one existing xrpld.

Does not restart managed services or read their databases. Bulk outputs go to the
explicit work directory; only the small report should be retained in the repository.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import signal
import shutil
import socket
import sqlite3
import subprocess
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def post(url, value, timeout=120):
    req = urllib.request.Request(url, json.dumps(value).encode(),
                                 {'Content-Type': 'application/json'})
    return urllib.request.urlopen(req, timeout=timeout)


def rpc(url, method, **params):
    with post(url, dict(method=method, params=[params])) as response:
        result = json.load(response)['result']
    if result.get('status') != 'success' or 'error' in result:
        raise RuntimeError(result)
    return result


def measure(args, index, ledger_hash, mode):
    data = args.work / mode
    if data.exists():
        raise RuntimeError(f'{data} already exists; use a new work directory for a fresh comparison')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    url = f'http://127.0.0.1:{port}'
    command = [str(args.work / 'xlb'), '--data', str(data), '--listen', f'127.0.0.1:{port}',
               '--rpc', args.rpc, '--peer', args.peer, '--network-id', str(args.network_id)]
    with (args.work / f'{mode}.log').open('w') as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=log)
        try:
            for _ in range(100):
                if process.poll() is not None:
                    raise RuntimeError(f'{mode} backend exited; see {log.name}')
                try:
                    with urllib.request.urlopen(url + '/health', timeout=1):
                        break
                except OSError:
                    time.sleep(.1)
            else:
                raise RuntimeError('temporary backend did not start')
            started = time.monotonic()
            last_print = 0
            result = None
            with (args.work / f'{mode}.ndjson').open('w') as events:
                with post(url + '/fetch/stream', dict(
                        **{'from': index}, state=True, ledger_hash=ledger_hash, transport=mode)) as response:
                    for line in response:
                        event = json.loads(line)
                        events.write(json.dumps(event) + '\n')
                        events.flush()
                        now = time.monotonic()
                        if event['event'] == 'error':
                            raise RuntimeError(event['error'])
                        if event['event'] == 'result':
                            result = event['data'][0]
                        elif now-last_print > 30:
                            print(json.dumps(dict(transport=mode, wall_seconds=round(now-started, 2),
                                                  progress=event)), flush=True)
                            last_print = now
            wall = time.monotonic()-started
            assert result and result['ledger_hash'] == ledger_hash
            assert result['acquisition_transport'] == mode and result['trust'] == 'untrusted'
            assert result['state_downloaded'] and not result['metrics'].get('reused')
            with sqlite3.connect(data / 'xl.sqlite3') as db:
                assert db.execute('SELECT count(*) FROM trust_anchors').fetchone()[0] == 0
                assert db.execute('SELECT count(*) FROM verifications').fetchone()[0] == 0
                path = json.loads(db.execute('SELECT sources_json FROM states').fetchone()[0])[0]
            with sqlite3.connect(path) as db:
                nodes, leaves, node_bytes, pending = db.execute(
                    'SELECT nodes,leaves,bytes,pending FROM counters WHERE id=1').fetchone()
                assert pending == 0
            return dict(transport=mode, wall_seconds=wall, entries_per_second=leaves/wall,
                        nodes=nodes, entries=leaves, stored_node_bytes=node_bytes, result=result)
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=25)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                    raise RuntimeError('temporary benchmark backend did not stop gracefully')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rpc', default='http://127.0.0.1:5005')
    parser.add_argument('--peer', required=True)
    parser.add_argument('--ledger-index', default='validated')
    parser.add_argument('--ledger-hash')
    parser.add_argument('--network-id', type=int, default=0)
    parser.add_argument('--order', choices=['peer,rpc', 'rpc,peer', 'peer', 'rpc'], default='peer,rpc',
                        metavar='TRANSPORTS', help='peer,rpc (default), rpc,peer, peer, or rpc')
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    args.work = args.work.resolve()
    args.work.mkdir(parents=True, exist_ok=False)
    info = rpc(args.rpc, 'server_info')['info']
    if 'network_id' in info:
        assert info['network_id'] == args.network_id
    else:
        assert args.network_id == 0
    selection = dict(ledger_hash=args.ledger_hash) if args.ledger_hash else dict(
        ledger_index=int(args.ledger_index) if args.ledger_index.isdigit() else args.ledger_index)
    ledger = rpc(args.rpc, 'ledger', binary=True, **selection)
    ledger_hash = ledger['ledger_hash'].upper()
    index = int(ledger['ledger_index'])
    binary = args.work / 'xlb'
    shutil.copy2(ROOT / '.lake/build/bin/xlb', binary)
    report = dict(started_utc=datetime.now(timezone.utc).isoformat(),
                  ledger_index=index, ledger_hash=ledger_hash, network_id=args.network_id,
                  rpc=args.rpc, peer=args.peer, xrpld_version=info['build_version'],
                  xlb_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  platform=platform.platform(), order=args.order.split(','), measurements=[],
                  method='Fresh independent stores, sequential runs on one xrpld; OS/node caches are not cleared. '
                         'One configured peer connection; no discovery. Integrity checks remain enabled. '
                         'Acquisition does not create operator trust or kernel proof receipts.')
    target = args.work / 'report.json'
    target.write_text(json.dumps(report, indent=2) + '\n')
    try:
        for mode in report['order']:
            report['measurements'].append(measure(args, index, ledger_hash, mode))
            target.write_text(json.dumps(report, indent=2) + '\n')
        if len(report['measurements']) == 2:
            first, second = report['measurements']
            assert first['entries'] == second['entries']
            assert first['result']['state_root'] == second['result']['state_root']
            by_mode = {m['transport']: m for m in report['measurements']}
            report['rpc_over_peer_wall_ratio'] = by_mode['rpc']['wall_seconds']/by_mode['peer']['wall_seconds']
    except BaseException as error:
        report['error'] = str(error)
        raise
    finally:
        report['finished_utc'] = datetime.now(timezone.utc).isoformat()
        target.write_text(json.dumps(report, indent=2) + '\n')
        print('Report:', target, flush=True)


if __name__ == '__main__':
    main()
