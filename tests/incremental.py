"""Full-state reuse per bundle: changed nodes only, all old objects retained, real proofs."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

from acquisition import header
from integration import ROOT, backend, cli, queue, request
from peer_acquisition import frame, pb, pn, peer
from progress import stream

PROBE = ROOT / '.lake/build/bin/state_view_probe'
ZERO = bytes(32)


def half(blob):
    return hashlib.sha512(blob).digest()[:32]


def make_tree(entries):
    result = []
    def walk(items, path):
        if len(items) == 1 and path:
            key, data = items[0]
            wire = data + key + b'\x01'
            digest = half(b'MLN\0' + wire[:-1])
        else:
            children = []
            for branch in range(16):
                selected = [(k, v) for k, v in items if
                            (k[len(path)//2] >> (4 if len(path) % 2 == 0 else 0)) & 15 == branch]
                children.append(walk(selected, path + [branch]) if selected else ZERO)
            wire = b''.join(children) + b'\x02'
            digest = half(b'MIN\0' + wire[:-1])
        ident = bytes.fromhex(''.join(f'{n:X}' for n in path).ljust(64, '0')) + bytes([len(path)])
        result.append((ident, wire, digest))
        return digest
    return walk(sorted(entries.items()), []).hex().upper(), result


class Node(BaseHTTPRequestHandler):
    versions = {}
    calls = []
    def log_message(self, *args):
        pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        method, params = body['method'], body['params'][0]
        type(self).calls.append((method, params))
        if method == 'server_info':
            latest = max(self.versions)
            result = dict(status='success', info=dict(network_id=0, validated_ledger=dict(seq=latest)))
        else:
            index = params.get('ledger_index')
            if 'ledger_hash' in params:
                index = next((n for n, v in self.versions.items() if v['hash'] == params['ledger_hash']), None)
            v = self.versions.get(index)
            if not v:
                result = dict(status='error', error='lgrNotFound')
            elif method == 'ledger':
                result = dict(status='success', ledger_index=index, ledger_hash=v['hash'],
                              ledger=dict(closed=True, ledger_data=v['raw'], transactions=[]))
            else:
                assert method == 'ledger_data'
                start = int(params.get('marker', '0'))
                state = [dict(index=k.hex().upper(), data=d.hex().upper()) for k, d in sorted(v['entries'].items())]
                result = dict(status='success', ledger_index=index, ledger_hash=v['hash'], state=state[start:start+1024])
                if start+1024 < len(state):
                    result['marker'] = str(start+1024)
        encoded = json.dumps(dict(result=result)).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


def write_nodes(folder, index, records=None, corrupt=False):
    v = Node.versions[index]
    records = list(v['records'] if records is None else records)
    body = pb(1, bytes.fromhex(v['hash'])) + pn(2, index) + pn(3, 2)
    for ident, wire, digest in reversed(records):
        if corrupt and wire[-1] == 1:
            wire = bytes([wire[0] ^ 1]) + wire[1:]
        body += pb(4, pb(1, wire) + pb(2, ident))
    (folder / f"state-{v['hash']}.bin").write_bytes(frame(32, body))


def sources(data, bundle, index):
    with sqlite3.connect(data / 'xl.sqlite3') as db:
        text = db.execute('SELECT s.sources_json FROM states s JOIN ledgers l ON l.id=s.ledger_id '
                          'WHERE s.bundle=? AND l.idx=?', (bundle, index)).fetchone()[0]
    return json.loads(text)


def verify_full(tmp, data, bundle, index, success=True):
    manifest = tmp / 'sources.json'
    manifest.write_text(json.dumps(sources(data, bundle, index)))
    p = subprocess.run([str(PROBE), str(manifest), Node.versions[index]['root']],
                       capture_output=True, text=True, timeout=30)
    assert (p.returncode == 0) == success, (p.stdout[:500], p.stderr)
    if success:
        actual = {bytes.fromhex(e['index']): bytes.fromhex(e['data']) for e in json.loads(p.stdout)}
        assert actual == Node.versions[index]['entries'], (index, len(actual))


def partial(data, bundle, index):
    with sqlite3.connect(data / 'xl.sqlite3') as db:
        path, status, scope = db.execute('SELECT d.path,d.status,d.scope FROM peer_downloads d JOIN ledgers l ON l.id=d.ledger_id '
                                  'WHERE d.bundle=? AND l.idx=?', (bundle, index)).fetchone()
    with sqlite3.connect(path) as db:
        counts = db.execute('SELECT nodes,leaves,bytes,pending FROM acquisition_counters WHERE scope=?', (scope,)).fetchone() if scope else db.execute('SELECT nodes,leaves,bytes,pending FROM counters').fetchone()
        reused = db.execute("SELECT value FROM metadata WHERE key=?", (f"acquisition/{scope}/xl_peer_reused" if scope else "xl_peer_reused",)).fetchone()
    return path, status, counts, reused


def legacy_adoption(tmp, rpc, fixture, historical_data):
    # Upgrade a legacy full snapshot in place, explicitly discard an
    # unwanted duplicate download, and retire a superseded RPC partial.
    old_shared = Path(sources(historical_data, 'default', 214)[0])
    legacy_dir = historical_data / 'states'
    legacy_dir.mkdir(exist_ok=True)
    legacy_base = legacy_dir / 'legacy-base.sqlite3'
    with sqlite3.connect(historical_data / 'xl.sqlite3') as db:
        scope214 = db.execute('SELECT scope FROM peer_downloads d JOIN ledgers l ON l.id=d.ledger_id WHERE l.idx=214').fetchone()[0]
    with sqlite3.connect(old_shared) as db:
        records = db.execute('SELECT substr(key,?),value FROM metadata WHERE key LIKE ?',
                             (len(f'acquisition/{scope214}/')+1, f'acquisition/{scope214}/%')).fetchall()
        db.executemany('INSERT OR REPLACE INTO metadata VALUES(?,?)', records)
    db.close()
    source = sqlite3.connect(old_shared)
    copy = sqlite3.connect(legacy_base)
    try:
        source.backup(copy)
        copy.execute('PRAGMA journal_mode=DELETE')
    finally:
        copy.close()
        source.close()
    old_shared.unlink()
    shutil.move(str(old_shared) + '.nodes', str(legacy_base) + '.nodes')
    duplicate = legacy_dir / 'unwanted-200.sqlite3'
    rpc_partial = legacy_dir / 'superseded-rpc-214.sqlite3'
    old_view = legacy_dir / 'unused-view.sqlite3'
    for copy in (duplicate, rpc_partial):
        shutil.copy2(legacy_base, copy)
        shutil.copytree(str(legacy_base) + '.nodes', str(copy) + '.nodes')
    shutil.copy2(legacy_base, old_view)
    with sqlite3.connect(duplicate) as db:
        db.execute("INSERT OR REPLACE INTO metadata VALUES('xl_peer_view',?)", (str(old_view),))
    db.close()
    with sqlite3.connect(historical_data / 'xl.sqlite3') as db:
        db.execute('DELETE FROM states WHERE ledger_id IN (SELECT id FROM ledgers WHERE idx!=214)')
        db.execute('DELETE FROM peer_downloads WHERE ledger_id IN (SELECT id FROM ledgers WHERE idx!=214)')
        db.execute('UPDATE states SET sources_json=?', (json.dumps([str(legacy_base)]),))
        db.execute("UPDATE peer_downloads SET path=?,scope=''", (str(legacy_base),))
        db.execute("INSERT INTO peer_downloads(bundle,ledger_id,path,scope,status) SELECT 'default',id,?,'','downloading' FROM ledgers WHERE idx=200", (str(duplicate),))
        db.execute("INSERT INTO state_downloads(bundle,ledger_id,path,scope,status) SELECT 'default',id,?,'','downloading' FROM ledgers WHERE idx=214", (str(rpc_partial),))
        db.execute('DELETE FROM bundle_node_stores')
        # The v3 schema had no scope columns; recreate those two tables.
        for table in ('peer_downloads', 'state_downloads'):
            db.execute(f'CREATE TABLE {table}_old(bundle TEXT NOT NULL,ledger_id INTEGER NOT NULL,path TEXT NOT NULL UNIQUE,status TEXT NOT NULL,updated_at TEXT NOT NULL,PRIMARY KEY(bundle,ledger_id))')
            db.execute(f'INSERT INTO {table}_old SELECT bundle,ledger_id,path,status,updated_at FROM {table}')
            db.execute(f'DROP TABLE {table}')
            db.execute(f'ALTER TABLE {table}_old RENAME TO {table}')
        db.execute('PRAGMA user_version=3')
    with sqlite3.connect(legacy_base) as db:
        generation = db.execute('SELECT generation FROM node_storage').fetchone()[0]
    with peer(tmp, fixture) as (endpoint, _):
        with backend(historical_data, rpc, peer=endpoint) as (url, _):
            discarded = request(url, '/state/discard', dict(ledger_index=200, ledger_hash=Node.versions[200]['hash']))
            assert discarded['removed_stores'] == 2
            assert not duplicate.exists() and not Path(str(duplicate) + '.nodes').exists() and not old_view.exists()
            consolidated = request(url, '/state/consolidate', {})
            assert consolidated['node_store'] == str(legacy_base) and consolidated['removed_stores'] == 1
            assert not rpc_partial.exists() and not Path(str(rpc_partial) + '.nodes').exists()
            assert list(historical_data.rglob('nudb.dat')) == [next(Path(str(legacy_base) + '.nodes').rglob('nudb.dat'))]
            request(url, '/state/discard', dict(ledger_index=214, ledger_hash=Node.versions[214]['hash']), 422)
            verify_full(tmp, historical_data, 'default', 214)
            result = cli(url, 'fetch', 200, '--state', '--transport', 'peer')[0]
            assert result['metrics']['incremental'] and result['metrics']['entries'] < 20
            assert sources(historical_data, 'default', 200) == [str(legacy_base)]
            verify_full(tmp, historical_data, 'default', 200)
            verify_full(tmp, historical_data, 'default', 214)
            with sqlite3.connect(legacy_base) as db:
                assert db.execute('SELECT generation FROM node_storage').fetchone()[0] == generation


def main():
    subprocess.run(['lake', 'build', 'state_view_probe'], cwd=ROOT, check=True)
    entries = {int(i << 244).to_bytes(32, 'big'): bytes.fromhex('11006122000000002400000001') + bytes([i % 256])
               for i in range(4096)}
    parent = '00'*32
    inserted = bytes.fromhex('0008' + '00'*30)
    for index in range(200, 217):
        before = dict(entries)
        if index == 215:
            entries[inserted] = bytes.fromhex('11006122000000002400000001FF')
        elif index == 216:
            del entries[bytes(32)]
        elif index > 200 and index != 213:
            key = sorted(entries)[(index-201)*273 % len(entries)]
            entries[key] = entries[key][:-1] + bytes([(entries[key][-1]+1) % 256])
        root, records = make_tree(entries)
        raw, digest = header(index, root, parent)
        Node.versions[index] = dict(root=root, raw=raw, hash=digest, records=records, entries=dict(entries), before=before)
        parent = digest
    node = ThreadingHTTPServer(('127.0.0.1', 0), Node)
    thread = threading.Thread(target=node.serve_forever, daemon=True)
    thread.start()
    rpc = f'http://127.0.0.1:{node.server_port}'
    try:
        with tempfile.TemporaryDirectory(prefix='xl-incremental-') as directory:
            tmp = Path(directory).resolve()
            flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'openssl'], text=True))
            subprocess.run(['cc', '-O2', '-Wno-deprecated-declarations', str(ROOT / 'tests/mock_peer.c'),
                            '-o', str(tmp / 'mock_peer'), *flags], check=True)
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(tmp / 'key.pem'),
                            '-out', str(tmp / 'cert.pem'), '-days', '1', '-subj', '/CN=localhost'], capture_output=True, check=True)
            (tmp / 'tx.bin').write_bytes(b'ignored')
            fixture = tmp / 'fixture'
            fixture.mkdir()
            (fixture / 'validations.bin').write_bytes(b'')
            write_nodes(fixture, 200)
            for index in range(201, 217):
                old = {r[2] for r in Node.versions[index-1]['records']}
                changed = [r for r in Node.versions[index]['records'] if r[2] not in old]
                write_nodes(fixture, index, changed)
            if '--legacy-only' in sys.argv:
                historical_data = tmp / 'historical'
                write_nodes(fixture, 214)
                with peer(tmp, fixture) as (endpoint, _):
                    with backend(historical_data, rpc, peer=endpoint) as (url, _):
                        cli(url, 'fetch', 214, '--state', '--transport', 'peer')
                        cli(url, 'fetch', 200)
                base_hashes = {r[2] for r in Node.versions[214]['records']}
                write_nodes(fixture, 200, [r for r in Node.versions[200]['records'] if r[2] not in base_hashes])
                legacy_adoption(tmp, rpc, fixture, historical_data)
                print('PASS in-place legacy adoption, exact duplicate deletion, retained roots and unchanged NuDB generation')
                return
            data = tmp / 'data'
            with peer(tmp, fixture, connections=15) as (endpoint, _):
                with backend(data, rpc, peer=endpoint) as (url, _):
                    base = cli(url, 'state', 'new', '-b', 'alpha', '-i', 200, '--transport', 'peer')[0]
                    assert not base['metrics']['incremental'] and base['metrics']['entries'] == 4096
                    base_path = sources(data, 'alpha', 200)[0]

                    # Twelve versions exercise more source catalogs than the bounded index reader keeps open.
                    result = cli(url, 'state', 'update', '-b', 'alpha', '-i', ':212', '--transport', 'peer')
                    assert len(result) == 12
                    assert all(r['metrics']['nodes'] == 4 and r['metrics']['reused_subtrees'] == 45 for r in result)
                    assert all(r['metrics']['incremental'] for r in result)
                    assert sources(data, 'alpha', 212) == [base_path]
                    with sqlite3.connect(data / 'xl.sqlite3') as db:
                        assert db.execute("SELECT count(DISTINCT path) FROM peer_downloads WHERE bundle='alpha'").fetchone()[0] == 1
                        assert db.execute("SELECT count(DISTINCT scope) FROM peer_downloads WHERE bundle='alpha'").fetchone()[0] == 13
                    verify_full(tmp, data, 'alpha', 212)
                    verify_full(tmp, data, 'alpha', 200)
                    assert cli(url, 'state', 'info', '-b', 'alpha')['ledger_count'] == 13
                    # An identical root is fully retained locally, even with no peer request.
                    unchanged = cli(url, 'state', 'update', '-b', 'alpha', '-i', 213, '--transport', 'peer')[0]
                    assert unchanged['metrics']['requests'] == unchanged['metrics']['nodes'] == 0
                    assert unchanged['metrics']['reused_subtrees'] == 1
                    assert sources(data, 'alpha', 213) == [base_path]
                    verify_full(tmp, data, 'alpha', 213)
                    last = cli(url, 'state', 'update', '-b', 'alpha', '-i', 214, '--transport', 'peer')[0]
                    assert last['metrics']['nodes'] == 4
                    verify_full(tmp, data, 'alpha', 214)
                    # Another bundle must acquire its own full state rather than reusing alpha.
                    write_nodes(fixture, 201)
                    beta = cli(url, 'state', 'new', '-b', 'beta', '-i', 201, '--transport', 'peer')[0]
                    assert not beta['metrics']['incremental'] and beta['metrics']['entries'] == 4096
                    assert len(sources(data, 'beta', 201)) == 1
                    assert sources(data, 'beta', 201)[0] != sources(data, 'alpha', 201)[0]
                    verify_full(tmp, data, 'beta', 201)
                    assert {b['bundle'] for b in cli(url, 'state', 'list')} >= {'alpha', 'beta'}
                    # Exports are shared, while anchors and proof receipts are bundle-local.
                    v, p = Node.versions[214], Node.versions[213]
                    changed_keys = [k for k in v['entries'] if v['entries'][k] != p['entries'][k]]
                    export = dict(schema_version=1, stage='accepted', network_id=0, ledger_index=214,
                                  ledger_hash=v['hash'], parent_ledger_hash=p['hash'], parent_state_root=p['root'], state_root=v['root'],
                                  pre_transaction_changes=[dict(key=k.hex(), operation='modify', before=dict(blob=p['entries'][k].hex()),
                                                                after=dict(blob=v['entries'][k].hex())) for k in changed_keys],
                                  transactions=[], post_transaction_changes=[])
                    request(url, '/ledgers', export, 204)
                    alpha = url + '/bundles/alpha'
                    beta_url = url + '/bundles/beta'
                    queue(alpha, first=214, checks=['merkle'], expected='blocked')
                    cli(url, 'trust', 213, p['hash'], '-b', 'alpha')
                    proof = queue(alpha, first=214, checks=['merkle'])
                    assert proof['status'] == 'succeeded'
                    queue(beta_url, first=214, checks=['merkle'], expected='blocked')
                    assert cli(url, 'exports', '-b', 'beta')[0]['merkle'] == 'blocked'
                    assert cli(url, 'exports', '-b', 'alpha')[0]['merkle'] == 'kernel_checked'
                    with sqlite3.connect(data / 'xl.sqlite3') as db:
                        assert db.execute('SELECT count(*) FROM exports').fetchone()[0] == 1
                        assert db.execute('SELECT bundle FROM trust_anchors').fetchall() == [('alpha',)]
                        assert not db.execute('PRAGMA foreign_key_check').fetchall()
                    assert 'immediately' in cli(url, 'state', 'update', '-b', 'alpha', '-i', '216:217', success=False)
                    assert 'invalid bundle' in cli(url, 'state', 'info', '-b', '../alpha', success=False)
            # The RPC snapshot is a valid full base for the same incremental peer path.
            write_nodes(fixture, 201, [r for r in Node.versions[201]['records']
                                      if r[2] not in {old[2] for old in Node.versions[200]['records']}])
            with peer(tmp, fixture) as (endpoint, _):
                with backend(data, rpc, peer=endpoint) as (url, _):
                    cli(url, 'state', 'new', '-b', 'rpcbase', '-i', 200, '--transport', 'rpc')
                    delta = cli(url, 'state', 'update', '-b', 'rpcbase', '-i', 201, '--transport', 'peer')[0]
                    assert delta['metrics']['nodes'] == 4 and delta['metrics']['incremental']
                    verify_full(tmp, data, 'rpcbase', 201)
            # A hard crash and a flush/commit fault retain the exact parent and frontier.
            write_nodes(fixture, 202, [r for r in Node.versions[202]['records'] if r[0][-1] == 0])
            with peer(tmp, fixture) as (endpoint, _):
                with backend(data, rpc, peer=endpoint, expected_exit=-signal.SIGKILL) as (url, process):
                    with stream(url + '/bundles/rpcbase', {'from': 202, 'state': True, 'transport': 'peer'}) as response:
                        deadline = time.monotonic()+5
                        while time.monotonic() < deadline:
                            try:
                                saved = partial(data, 'rpcbase', 202)
                                if saved[2][0] == 1:
                                    break
                            except (TypeError, sqlite3.Error, FileNotFoundError):
                                pass
                            time.sleep(.002)
                        else:
                            raise AssertionError('no committed incremental root before crash')
                        process.kill()
                        process.wait(5)
            saved = partial(data, 'rpcbase', 202)
            assert saved[1] == 'downloading' and saved[2][0] == 1 and saved[2][-1] > 0
            with backend(data, rpc, peer=endpoint, expected_exit=86,
                         env={'LEANXRPL_STORAGE_TEST_FAULT': 'after-node-flush'}) as (url, process):
                with stream(url + '/bundles/rpcbase', {'from': 202, 'state': True, 'transport': 'peer'}) as response:
                    interrupted = [json.loads(line) for line in response if line.strip()]
                process.wait(10)
                assert not any(e.get('phase') == 'complete' for e in interrupted)
            assert partial(data, 'rpcbase', 202) == saved
            write_nodes(fixture, 202, [r for r in Node.versions[202]['records']
                                      if r[2] not in {old[2] for old in Node.versions[201]['records']}])
            with peer(tmp, fixture) as (endpoint, _):
                with backend(data, rpc, peer=endpoint) as (url, _):
                    completed = cli(url, 'state', 'update', '-b', 'rpcbase', '-i', 202, '--transport', 'peer')[0]
                    assert completed['metrics']['nodes'] == 4
                    assert partial(data, 'rpcbase', 202)[0] == saved[0]
                    verify_full(tmp, data, 'rpcbase', 202)
            # Invalid changed nodes cannot publish a delta or poison the shared index.
            delta203 = [r for r in Node.versions[203]['records']
                        if r[2] not in {old[2] for old in Node.versions[202]['records']}]
            write_nodes(fixture, 203, delta203, corrupt=True)
            with peer(tmp, fixture) as (endpoint, _):
                with backend(data, rpc, peer=endpoint) as (url, _):
                    cli(url, 'state', 'update', '-b', 'rpcbase', '-i', 203, success=False)
                    failed = partial(data, 'rpcbase', 203)
                    assert failed[1] == 'invalid' and failed[2][0] == 0
                    assert cli(url, 'state', 'info', '-b', 'rpcbase')['last_ledger'] == 202
                    verify_full(tmp, data, 'rpcbase', 202)
            write_nodes(fixture, 203, delta203)
            with peer(tmp, fixture) as (endpoint, _):
                with backend(data, rpc, peer=endpoint) as (url, _):
                    cli(url, 'state', 'update', '-b', 'rpcbase', '-i', 203, '--transport', 'peer')
                    assert partial(data, 'rpcbase', 203)[0] == failed[0] and Path(failed[0]).exists()
                    verify_full(tmp, data, 'rpcbase', 203)
            # Stalled incremental acquisition falls back to a full RPC snapshot of the same hash.
            write_nodes(fixture, 204, [r for r in Node.versions[204]['records'] if r[0][-1] == 0])
            with peer(tmp, fixture) as (endpoint, _):
                with backend(data, rpc, peer=endpoint, peer_timeout=1) as (url, _):
                    fallback = cli(url, 'state', 'update', '-b', 'rpcbase', '-i', 204)[0]
                    assert fallback['acquisition_transport'] == 'rpc' and fallback['fallback_reason']
                    assert fallback['ledger_hash'] == Node.versions[204]['hash']
                    assert cli(url, 'state', 'info', '-b', 'rpcbase')['status'] == 'complete'
                    verify_full(tmp, data, 'rpcbase', 204)
            with peer(tmp, fixture) as (endpoint, _):
                with backend(data, rpc, peer=endpoint) as (url, _):
                    result = cli(url, 'state', 'update', '-b', 'rpcbase', '-i', 205, '--transport', 'peer')[0]
                    assert result['metrics']['incremental'] and result['metrics']['nodes'] == 4
                    verify_full(tmp, data, 'rpcbase', 205)
                    # A forked node header cannot advance this bundle's contiguous tip.
                    original = Node.versions[206]
                    raw, digest = header(206, original['root'], 'FF'*32)
                    Node.versions[206] = dict(original, raw=raw, hash=digest)
                    try:
                        error = cli(url, 'state', 'update', '-b', 'rpcbase', '-i', 206, success=False)
                        assert 'exact preceding ledger' in error, error
                        assert cli(url, 'state', 'info', '-b', 'rpcbase')['last_ledger'] == 205
                    finally:
                        Node.versions[206] = original
            # Reopen all retained roots after process restart; source files remain sufficient.
            verify_full(tmp, data, 'alpha', 201)
            verify_full(tmp, data, 'alpha', 214)
            # Insert/delete changes move existing leaves to deeper/shallower positions.
            # Their old payloads are deliberately absent from peer replies and must be reused locally.
            write_nodes(fixture, 214)
            with peer(tmp, fixture, connections=3) as (endpoint, _):
                with backend(data, rpc, peer=endpoint) as (url, _):
                    cli(url, 'state', 'new', '-b', 'structure', '-i', 214, '--transport', 'peer')
                    added = cli(url, 'state', 'update', '-b', 'structure', '-i', 215, '--transport', 'peer')[0]
                    assert added['metrics']['incremental'] and added['metrics']['nodes'] <= 6
                    verify_full(tmp, data, 'structure', 215)
                    removed = cli(url, 'state', 'update', '-b', 'structure', '-i', 216, '--transport', 'peer')[0]
                    assert removed['metrics']['incremental'] and removed['metrics']['nodes'] <= 4
                    verify_full(tmp, data, 'structure', 216)
            # A saved full-download frontier can attach a later, non-parent
            # snapshot on restart. Only nodes absent from that snapshot are served.
            historical_data = tmp / 'historical'
            write_nodes(fixture, 200, [r for r in Node.versions[200]['records'] if r[0][-1] == 0])
            write_nodes(fixture, 214)
            with peer(tmp, fixture, connections=4) as (endpoint, _):
                with backend(historical_data, rpc, peer=endpoint, peer_timeout=1) as (url, _):
                    cli(url, 'fetch', 200, '--state', '--transport', 'peer', success=False)
                    saved = partial(historical_data, 'default', 200)
                    assert saved[2][0] == 1 and saved[2][-1] > 0
                    with sqlite3.connect(saved[0]) as db:
                        assert db.execute("SELECT value FROM metadata WHERE key LIKE 'acquisition/peer-%/xl_peer_base'").fetchone()[0] == 'null'
                    cli(url, 'fetch', 214, '--state', '--transport', 'peer')
                base_hashes = {r[2] for r in Node.versions[214]['records']}
                for index in (200, 210):
                    write_nodes(fixture, index, [r for r in Node.versions[index]['records'] if r[2] not in base_hashes])
                with backend(historical_data, rpc, peer=endpoint) as (url, _):
                    for index in (200, 210):
                        result = cli(url, 'fetch', index, '--state', '--transport', 'peer')[0]
                        metrics = result['metrics']
                        assert metrics['incremental'] and metrics['base_ledger_hash'] == Node.versions[214]['hash']
                        assert metrics['reused_subtrees'] > 0 and metrics['entries'] < 20
                        verify_full(tmp, historical_data, 'default', index)
                    assert partial(historical_data, 'default', 200)[0] == saved[0]
                    verify_full(tmp, historical_data, 'default', 214)
                    assert cli(url, 'jobs') == []
            legacy_adoption(tmp, rpc, fixture, historical_data)
        print('PASS full 4096-object state retained across 14 updates, four changed nodes per update, '
              '45 whole subtrees reused, zero-request identical roots, one physical store per bundle, peer/RPC bases, '
              'bundle isolation, shared exports, independent trust/proofs, real kernel checking, '
              'non-parent historical/gapped reuse, base attachment, in-place adoption and explicit duplicate deletion')
    finally:
        node.shutdown()
        node.server_close()
        thread.join()


if __name__ == '__main__':
    main()
