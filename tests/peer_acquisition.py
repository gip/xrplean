"""Signed single-peer acquisition, fail-closed integrity, fallback, and hard-crash recovery."""
from contextlib import contextmanager
from http.server import ThreadingHTTPServer
import hashlib
import json
from pathlib import Path
import shlex
import signal
import sqlite3
import subprocess
import tempfile
import threading
import time

from acquisition import Node, STATE_ROOT, ENTRIES
from integration import ROOT, TREE, backend, cli, free_port, queue, request
from progress import stream
from tasks import wait_task


def varint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes(result + bytes([value]))


def pn(field, value):
    return varint(field * 8) + varint(value)


def pb(field, value):
    return varint(field * 8 + 2) + varint(len(value)) + value


def frame(kind, payload):
    return len(payload).to_bytes(4, 'big') + kind.to_bytes(2, 'big') + payload


def nodes():
    by_hash = {n['hash']: bytes.fromhex(n['wire']) for n in TREE['nodes']}
    result = []

    def walk(digest, path):
        wire = by_hash[digest]
        ident = bytes.fromhex((''.join(f'{n:X}' for n in path)).ljust(64, '0')) + bytes([len(path)])
        result.append((ident, wire))
        if wire[-1] == 2:
            for branch in range(16):
                child = wire[branch*32:(branch+1)*32]
                if any(child):
                    walk(child.hex().upper(), path + [branch])
    walk(STATE_ROOT, [])
    return result


def write_reply(folder, records, digest=Node.hash200, sequence=200):
    payload = pb(1, bytes.fromhex(digest)) + pn(2, sequence) + pn(3, 2)
    for ident, wire in reversed(records):  # children deliberately precede parents
        payload += pb(4, pb(1, wire) + pb(2, ident))
    (folder / f'state-{Node.hash200}.bin').write_bytes(frame(32, payload))


@contextmanager
def peer(tmp, folder, mode='ledger', connections=1):
    server = subprocess.Popen([str(tmp / 'mock_peer'), '0', str(tmp / 'cert.pem'),
                               str(tmp / 'key.pem'), str(tmp / 'tx.bin'), mode, str(connections), str(folder)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        line = server.stdout.readline()
        assert line.startswith('port='), (line, server.stderr.read())
        yield f'127.0.0.1:{line.strip().split("=")[1]}', server
    finally:
        if server.poll() is None:
            server.terminate()
        server.communicate(timeout=10)


def checkpoint(data):
    with sqlite3.connect(data / 'xl.sqlite3') as db:
        path, status, scope = db.execute('SELECT path,status,scope FROM peer_downloads').fetchone()
        assert db.execute('SELECT count(*) FROM trust_anchors').fetchone()[0] == 0
    with sqlite3.connect(path) as db:
        counts = db.execute('SELECT nodes,leaves,bytes,pending FROM acquisition_counters WHERE scope=?', (scope,)).fetchone() if scope else db.execute('SELECT nodes,leaves,bytes,pending FROM counters').fetchone()
    return path, status, counts


def main():
    node = ThreadingHTTPServer(('127.0.0.1', 0), Node)
    thread = threading.Thread(target=node.serve_forever, daemon=True)
    thread.start()
    rpc = f'http://127.0.0.1:{node.server_port}'
    try:
        with tempfile.TemporaryDirectory(prefix='xl-peer-tests-') as directory:
            tmp = Path(directory)
            flags = shlex.split(subprocess.check_output(
                ['pkg-config', '--cflags', '--libs', 'openssl'], text=True))
            subprocess.run(['cc', '-O2', '-Wno-deprecated-declarations',
                            str(ROOT / 'tests/mock_peer.c'), '-o', str(tmp / 'mock_peer'), *flags], check=True)
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                            '-keyout', str(tmp / 'key.pem'), '-out', str(tmp / 'cert.pem'),
                            '-days', '1', '-subj', '/CN=localhost'], check=True, capture_output=True)
            (tmp / 'tx.bin').write_bytes(b'ignored transaction gossip')
            fixture = tmp / 'fixture'
            fixture.mkdir()
            (fixture / 'validations.bin').write_bytes(b'')
            records = nodes()
            write_reply(fixture, records)
            # Different valid encodings of the same inner commitment must not
            # overwrite a visible payload or be mistaken for conflicting orphans.
            witnesses = list(TREE['nodes'])
            inner = next(n for n in witnesses if n['wire'].endswith('02'))
            full = bytes.fromhex(inner['wire'])
            sparse = b''.join(full[i*32:(i+1)*32] + bytes([i])
                              for i in range(16) if any(full[i*32:(i+1)*32])) + b'\x03'
            witnesses.append(dict(hash=inner['hash'], wire=sparse.hex().upper()))
            with backend(tmp / 'duplicate-wire', rpc) as (url, _):
                cli(url, 'fetch', 200)
                request(url, '/state', dict(ledger_index=200, ledger_hash=Node.hash200,
                                             nodes=witnesses), 201)
                with sqlite3.connect(tmp / 'duplicate-wire/xl.sqlite3') as db:
                    source = json.loads(db.execute('SELECT sources_json FROM states').fetchone()[0])[0]
                with sqlite3.connect(source) as db:
                    assert db.execute('SELECT nodes FROM counters').fetchone()[0] == len(TREE['nodes'])
                    assert db.execute('SELECT bytes FROM node_catalog WHERE hash=?',
                                      (bytes.fromhex(inner['hash']),)).fetchone()[0] == len(full)
            Node.calls = []
            with peer(tmp, fixture) as (endpoint, server):
                with backend(tmp / 'good', rpc, peer=endpoint) as (url, _):
                    result = cli(url, 'fetch', 200, '--state', '--transport', 'peer', '--hash', Node.hash200)[0]
                    assert result['acquisition_transport'] == 'peer' and result['state_root'] == STATE_ROOT
                    assert result['metrics']['entries'] == len(ENTRIES)
                    assert result['trust'] == 'untrusted'
                    assert not any(m == 'ledger_data' for m, _ in Node.calls)
                    out, err = server.communicate(timeout=10)
                    assert server.returncode == 0, err
                    assert 'ledger_requests=1' in out and 'outbound_controls=1' in out, out
                    path, status, counts = checkpoint(tmp / 'good')
                    assert status == 'complete' and counts[0] == len(records) and counts[-1] == 0
                    assert request(url, '/ledgers')[0]['state'] == 'peer_snapshot'
                    assert cli(url, 'fetch', 200, '--state', '--transport', 'peer')[0]['metrics']['reused']
                    # Snapshot download itself must not create proof receipts.
                    assert cli(url, 'jobs') == []
                    cli(url, 'trust', 200, Node.hash200)
                    export = dict(schema_version=1, stage='accepted', network_id=0, ledger_index=201,
                                  ledger_hash=Node.hash201, parent_ledger_hash=Node.hash200,
                                  parent_state_root=STATE_ROOT, state_root=STATE_ROOT,
                                  pre_transaction_changes=[], transactions=[], post_transaction_changes=[])
                    request(url, '/ledgers', export, 204)
                    proof = queue(url, first=201, checks=['merkle'])
                    assert proof['status'] == 'succeeded'
            # Auto uses the advertised port on the RPC host; an explicit peer
            # overrides it, and forced RPC never opens the advertised endpoint.
            for selection in ('advertised', 'override', 'forced_rpc'):
                Node.calls = []
                with peer(tmp, fixture) as (endpoint, _):
                    Node.ports = [dict(port=endpoint.rsplit(':', 1)[1], protocol=['peer'],
                                       host='untrusted-advertised-host.invalid')]
                    explicit = endpoint if selection == 'override' else None
                    if explicit:
                        Node.ports[0]['port'] = str(free_port())
                    try:
                        with backend(tmp / selection, rpc, peer=explicit) as (url, _):
                            args = ('--transport', 'rpc') if selection == 'forced_rpc' else ()
                            result = cli(url, 'fetch', 200, '--state', *args)[0]
                            assert result['acquisition_transport'] == ('rpc' if args else 'peer')
                            assert any(m == 'ledger_data' for m, _ in Node.calls) == bool(args)
                    finally:
                        Node.ports = None
            # xrpld's reply cap may leave most requested IDs unserved. They
            # must be eligible immediately, without a ten-second lease stall.
            for ident, wire in records:
                payload = pb(1, bytes.fromhex(Node.hash200)) + pn(2, 200) + pn(3, 2)
                payload += pb(4, pb(1, wire) + pb(2, ident))
                (fixture / f'capped-{ident.hex().upper()}.bin').write_bytes(frame(32, payload))
            with peer(tmp, fixture, 'capped') as (endpoint, _):
                with backend(tmp / 'capped', rpc, peer=endpoint) as (url, _):
                    started = time.monotonic()
                    result = cli(url, 'fetch', 200, '--state', '--transport', 'peer')[0]
                    assert time.monotonic()-started < 5, 'capped reply waited for a lease timeout'
                    assert result['metrics']['entries'] == len(ENTRIES)
                    assert checkpoint(tmp / 'capped')[2][-1] == 0
            for label, ports in (
                    ('absent', None), ('malformed', 'peer'),
                    ('bad_port', [dict(port='65536', protocol=['peer'])]),
                    ('wrong_protocol', [dict(port='2459', protocol=['http'])])):
                Node.ports = ports
                try:
                    with backend(tmp / f'ports-{label}', rpc) as (url, _):
                        result = cli(url, 'fetch', 200, '--state')[0]
                        assert result['acquisition_transport'] == 'rpc'
                        assert 'did not advertise' in result['fallback_reason']
                        with sqlite3.connect(tmp / f'ports-{label}/xl.sqlite3') as db:
                            events = [json.loads(row[0]) for row in db.execute(
                                'SELECT event_json FROM acquisition_events')]
                        assert any(e.get('phase') == 'rpc_fallback' and
                                   'did not advertise' in e['last_error'] for e in events)
                finally:
                    Node.ports = None
            for mode in ('bad-signature', 'features'):
                Node.calls = []
                with peer(tmp, fixture, mode) as (endpoint, _):
                    with backend(tmp / mode, rpc, peer=endpoint) as (url, _):
                        result = cli(url, 'fetch', 200, '--state')[0]
                        assert result['acquisition_transport'] == 'rpc' and result['fallback_reason']
                        assert all(p['ledger_hash'] == Node.hash200 for m, p in Node.calls if m == 'ledger_data')
                        assert request(url, '/ledgers')[0]['trust'] == 'untrusted'
            # No discovery or redirect connections; a refused endpoint falls back to exact-hash RPC.
            with backend(tmp / 'refused', rpc, peer=f'127.0.0.1:{free_port()}') as (url, _):
                result = cli(url, 'fetch', 200, '--state')[0]
                assert result['acquisition_transport'] == 'rpc' and result['fallback_reason']
            for mode in ('corrupt', 'wrong_hash', 'wrong_sequence'):
                altered = list(records)
                if mode == 'corrupt':
                    ident, wire = altered[-1]
                    altered[-1] = (ident, bytes([wire[0] ^ 1]) + wire[1:])
                write_reply(fixture, altered,
                            digest='FF'*32 if mode == 'wrong_hash' else Node.hash200,
                            sequence=201 if mode == 'wrong_sequence' else 200)
                Node.calls = []
                with peer(tmp, fixture) as (endpoint, _):
                    with backend(tmp / mode, rpc, peer=endpoint) as (url, _):
                        cli(url, 'fetch', 200, '--state', success=False)
                        assert not any(m == 'ledger_data' for m, _ in Node.calls)
                        path, status, counts = checkpoint(tmp / mode)
                        assert status == 'invalid' and counts[0] == 0 and counts[-1] == 1
                        assert request(url, '/ledgers')[0]['state'] == 'missing'
                        assert cli(url, 'jobs') == []
            # A hard kill retains the committed frontier and never publishes partial state.
            data = tmp / 'crash'
            write_reply(fixture, records[:1])
            with peer(tmp, fixture) as (endpoint, _):
                with backend(data, rpc, peer=endpoint, expected_exit=-signal.SIGKILL) as (url, process):
                    with stream(url, {'from': 200, 'state': True, 'transport': 'peer'}) as response:
                        while True:
                            event = json.loads(response.readline())
                            if event.get('nodes', 0) > 0:
                                break
                        path, status, counts = checkpoint(data)
                        assert status == 'downloading' and counts[0] == 1 and counts[-1] == len(ENTRIES)
                        assert request(url, '/ledgers')[0]['state'] == 'missing'
                        process.kill()
                        process.wait(5)
            # An older writer may have persisted future retry leases. They are
            # scheduling hints, so reopening must make every missing path ready.
            with sqlite3.connect(path) as db:
                db.execute('CREATE INDEX IF NOT EXISTS pending_due ON pending(due,id)')
                db.execute('UPDATE pending SET due=?', (2**62,))
            write_reply(fixture, records)
            with peer(tmp, fixture) as (endpoint, _):
                with backend(data, rpc, peer=endpoint) as (url, _):
                    started = time.monotonic()
                    result = cli(url, 'fetch', 200, '--state', '--transport', 'peer')[0]
                    assert time.monotonic()-started < 5, 'legacy persisted leases delayed resume'
                    assert result['acquisition_transport'] == 'peer'
                    assert checkpoint(data)[0] == path and checkpoint(data)[2][-1] == 0
                    with sqlite3.connect(path) as db:
                        assert not db.execute("SELECT 1 FROM sqlite_master WHERE name='pending_due'").fetchone()
            # Configuring a peer after an interrupted RPC fetch tries the peer first.
            # If that peer is unavailable, fallback resumes the old exact-hash cursor.
            for scenario in ('switch', 'fallback_resume'):
                data = tmp / scenario
                paused, release = threading.Event(), threading.Event()
                def gate(page):
                    if page == 1:
                        paused.set()
                        assert release.wait(10)
                Node.state_page_gate = gate
                try:
                    with backend(data, rpc, expected_exit=-signal.SIGKILL) as (url, process):
                        with stream(url, {'from': 200, 'state': True, 'transport': 'rpc'}) as response:
                            while True:
                                event = json.loads(response.readline())
                                if event.get('pages') == 1:
                                    break
                            assert paused.wait(5)
                            process.kill()
                            process.wait(5)
                            release.set()
                finally:
                    release.set()
                    Node.state_page_gate = None
                Node.calls = []
                with peer(tmp, fixture, 'ledger' if scenario == 'switch' else 'bad-signature') as (endpoint, _):
                    with backend(data, rpc, peer=endpoint) as (url, _):
                        result = cli(url, 'fetch', 200, '--state')[0]
                        pages = [p.get('marker') for m, p in Node.calls if m == 'ledger_data']
                        assert result['acquisition_transport'] == ('peer' if scenario == 'switch' else 'rpc')
                        assert pages == ([] if scenario == 'switch' else ['1', '2', '3']), pages
                        assert request(url, '/ledgers')[0]['trust'] == 'untrusted'
            # Explicit cancellation flushes pending peer batches and releases the bundle.
            write_reply(fixture, records[:1])
            cancel_data = tmp / 'cancel-peer'
            with peer(tmp, fixture) as (endpoint, _):
                with backend(cancel_data, rpc, peer=endpoint) as (url, _):
                    task = cli(url, 'ledger', 'get', '-i', 200, '--state', '--transport', 'peer', '--detach')
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        detail = request(url, '/tasks/' + task['task_id'])
                        progress = detail['progress'] or {}
                        if progress.get('phase') == 'peer_downloading' and progress.get('nodes', 0) > 0:
                            break
                        time.sleep(.02)
                    else:
                        raise AssertionError(detail)
                    started = time.monotonic()
                    cli(url, 'task', 'cancel', '--id', task['task_id'])
                    wait_task(url, task['task_id'], 'cancelled')
                    assert time.monotonic() - started < 3
                    assert checkpoint(cancel_data)[1] == 'downloading'
                    assert checkpoint(cancel_data)[2][0] >= 1
            write_reply(fixture, records)
            with peer(tmp, fixture) as (endpoint, _):
                with backend(cancel_data, rpc, peer=endpoint) as (url, _):
                    retry = cli(url, 'task', 'retry', '--id', task['task_id'])
                    resumed = wait_task(url, retry['task_id'])
                    assert resumed['result'][0]['acquisition_transport'] == 'peer'
                    assert resumed['result'][0]['state_downloaded'] is True
                    assert request(url, '/tasks/' + task['task_id'])['status'] == 'cancelled'
            # Stalling preserves its attempt, and auto falls back with isolated transport checkpoint namespaces.
            write_reply(fixture, records[:1])
            with peer(tmp, fixture) as (endpoint, _):
                with backend(tmp / 'stall', rpc, peer=endpoint, peer_timeout=1) as (url, _):
                    result = cli(url, 'fetch', 200, '--state')[0]
                    assert result['acquisition_transport'] == 'rpc' and 'stalled' in result['fallback_reason']
                    assert checkpoint(tmp / 'stall')[1] == 'downloading'
                    with sqlite3.connect(tmp / 'stall/xl.sqlite3') as db:
                        assert db.execute('SELECT path FROM state_downloads').fetchone()[0] == checkpoint(tmp / 'stall')[0]
                        assert db.execute('SELECT scope FROM state_downloads').fetchone()[0] != db.execute('SELECT scope FROM peer_downloads').fetchone()[0]
        print('PASS one signed peer, direct NuDB tree, exact identity/root, untrusted receipt, real kernel proof, '
              'corruption rejection, explicit cancellation/resume, handshake/stall fallback, one shared catalog with isolated transport scopes, hard-crash resume, complete reuse')
    finally:
        node.shutdown()
        node.server_close()
        thread.join()


if __name__ == '__main__':
    main()
