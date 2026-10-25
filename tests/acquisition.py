"""Historical RPC acquisition, pagination, bootstrap, and malformed-input checks."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import copy
import hashlib
import json
import socket
import sqlite3
import tempfile
import threading
import time
from integration import ROOT, TREE, backend, cli, queue, request

ZERO = '00' * 32
STATE_ROOT = json.loads((ROOT / 'fixtures/payment-audit.json').read_text())['parent_state_root']
ENTRIES = sorted([{'index': n['wire'][-66:-2], 'data': n['wire'][:-66]}
                  for n in TREE['nodes'] if n['wire'][-2:] == '01'], key=lambda e: e['index'])


def header(index, root=STATE_ROOT, parent=ZERO):
    raw = (index.to_bytes(4, 'big') + (1000000000).to_bytes(8, 'big') + bytes.fromhex(parent) +
           bytes(32) + bytes.fromhex(root) + bytes(8) + bytes([10, 0]))
    assert len(raw) == 118
    return raw.hex().upper(), hashlib.sha512(b'LWR\0' + raw).digest()[:32].hex().upper()


class Node(BaseHTTPRequestHandler):
    network = 0
    network_id_mode = 'omitted'
    mode = 'good'
    calls = []
    state_page_gate = None
    ports = None
    raw200, hash200 = header(200)
    raw201, hash201 = header(201, parent=hash200)

    def log_message(self, *args):
        pass

    def do_POST(self):
        posted = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        method, params = posted['method'], posted['params'][0]
        type(self).calls.append((method, params))
        if method == 'server_info':
            info = {} if self.network_id_mode == 'omitted' else {'network_id': self.network}
            if self.ports is not None:
                info['ports'] = self.ports
            if self.network_id_mode == 'malformed_info':
                info = None
            result = {'status': 'success', 'info': info}
        elif method == 'ledger':
            index = params.get('ledger_index')
            if 'ledger_hash' in params:
                index = {self.hash200: 200, self.hash201: 201}.get(params['ledger_hash'])
            if index not in (200, 201):
                result = {'status': 'error', 'error': 'lgrNotFound'}
            else:
                result = {'status': 'success', 'ledger_index': index,
                          'ledger_hash': self.hash200 if index == 200 else self.hash201,
                          'ledger': {'closed': True, 'ledger_data': self.raw200 if index == 200 else self.raw201,
                                     'transactions': []}}
        elif method == 'ledger_data':
            assert params['ledger_hash'] == self.hash200
            page = int(params.get('marker', '0'))
            if type(self).state_page_gate is not None:
                type(self).state_page_gate(page)
            rows = copy.deepcopy(ENTRIES[page:page+1])
            if self.mode == 'bad_blob' and rows:
                rows[0]['data'] = rows[0]['data'][:-2] + f"{int(rows[0]['data'][-2:],16)^1:02X}"
            result = {'status': 'success', 'ledger_index': 200,
                      'ledger_hash': self.hash200, 'state': rows}
            if page + 1 < len(ENTRIES):
                result['marker'] = str(page if self.mode == 'repeat' else page+1)
            if self.mode == 'wrong_page':
                result['ledger_hash'] = 'ff' * 32
        else:
            raise AssertionError(method)
        body = json.dumps({'result': result}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Crash/restart tests deliberately abandon in-flight RPCs.


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Node)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    rpc = f'http://127.0.0.1:{server.server_port}'
    try:
        with tempfile.TemporaryDirectory(prefix='xl-acquire-') as tmp:
            folder = Path(tmp)
            with backend(folder / 'data', rpc) as (url, _):
                result = cli(url, 'ledger', 'get', '--bundle', 'default', '--index', '200:201')
                assert [r['ledger_index'] for r in result] == [200, 201]
                assert all(r['trust'] == 'untrusted' for r in result)
                assert cli(url, 'jobs') == []
                cli(url, 'ledger', 'get', '--index', 200, '--state')
                assert sum(method == 'ledger_data' for method, _ in Node.calls) == len(ENTRIES)
                rows = cli(url, 'ledger', 'show', '--index', 200, '--hash', Node.hash200)
                assert len(rows) == 1
                state = rows[0]
                assert cli(url, 'ledger', 'show', '--index', 202) == []
                assert state['state'] == 'rpc_snapshot' and state['trust'] == 'untrusted'
                with sqlite3.connect(folder / 'data/xl.sqlite3') as db:
                    sources = json.loads(db.execute('SELECT sources_json FROM states').fetchone()[0])
                with sqlite3.connect(sources[0]) as catalog:
                    assert catalog.execute('SELECT backend FROM node_storage').fetchone()[0] == 'nudb-v1'
                    assert catalog.execute('SELECT count(*) FROM nodes').fetchone()[0] == 0
                    assert catalog.execute('SELECT count(*) FROM node_catalog').fetchone()[0] > 0
                assert list(Path(sources[0] + '.nodes').rglob('nudb.dat'))
                cli(url, 'trust', 200, Node.hash200)
                export = dict(schema_version=1, stage='accepted', network_id=0, ledger_index=201,
                              ledger_hash=Node.hash201, parent_ledger_hash=Node.hash200,
                              parent_state_root=STATE_ROOT, state_root=STATE_ROOT,
                              pre_transaction_changes=[], transactions=[], post_transaction_changes=[])
                request(url, '/ledgers', export, 204)
                queue(url, first=201, checks=['merkle'])
                # Omitted ID is the unconfigured Mainnet default; explicit IDs are checked strictly.
                Node.network_id_mode = 'explicit'
                cli(url, 'fetch', 200)
                Node.network = 1
                assert 'does not match XLB configuration' in cli(url, 'fetch', 200, success=False)
                for invalid in (None, '0', True, -1, 2**32, 0.5):
                    Node.network = invalid
                    assert 'unsigned 32-bit integer' in cli(url, 'fetch', 200, success=False)
                Node.network = 0
                Node.network_id_mode = 'malformed_info'
                cli(url, 'fetch', 200, success=False)
                Node.network_id_mode = 'explicit'
                # Missing historical data and corrupted pagination fail explicitly.
                cli(url, 'fetch', 202, success=False)
                with sqlite3.connect(folder / 'data/xl.sqlite3') as db:
                    assert db.execute('SELECT count(*) FROM states').fetchone()[0] == 1
                    assert db.execute('SELECT count(*) FROM trust_anchors').fetchone()[0] == 1
                # Reject ambiguous HTTP framing without accepting an export.
                address = url.removeprefix('http://').split(':')
                with socket.create_connection((address[0], int(address[1]))) as sock:
                    sock.sendall(b'POST /ledgers HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n')
                    assert b'400 Bad Request' in sock.recv(4096)
            Node.network_id_mode = 'omitted'
            for mode in ('wrong_page', 'repeat', 'bad_blob'):
                Node.mode = mode
                with backend(folder / mode, rpc) as (url, _):
                    cli(url, 'fetch', 200, '--state', success=False)
                    with sqlite3.connect(folder / mode / 'xl.sqlite3') as db:
                        assert db.execute('SELECT count(*) FROM states').fetchone()[0] == 0
            Node.mode = 'good'
            with backend(folder / 'non-mainnet', rpc, network=1) as (url, _):
                assert 'non-Mainnet acquisition requires an explicit' in cli(url, 'fetch', 200, success=False)
                with sqlite3.connect(folder / 'non-mainnet/xl.sqlite3') as db:
                    assert db.execute('SELECT count(*) FROM ledgers').fetchone()[0] == 0
                Node.network_id_mode = 'explicit'
                Node.network = 0
                assert 'does not match XLB configuration' in cli(url, 'fetch', 200, success=False)
                Node.network = 1
                assert cli(url, 'fetch', 200)[0]['ledger_index'] == 200
        print('PASS inclusive historical fetch, pinned paginated state, RPC bootstrap to real kernel proof, optional Mainnet ID, strict network validation, corrupt state, missing ledgers, framing')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    main()
