"""Read-only bounded node observations, cache sharing and health independence."""
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import tempfile
import threading
import time
from integration import backend, request, free_port


class Node(BaseHTTPRequestHandler):
    mode = 'ok'
    count = 0
    entered = threading.Event()
    release = threading.Event()

    def do_POST(self):
        Node.count += 1
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert body['method'] == 'server_info'
        info = dict(server_state='full', build_version='test', complete_ledgers='199-201',
                    validated_ledger=dict(seq=201, hash='A' * 64))
        if Node.mode == 'slow':
            Node.entered.set()
            Node.release.wait(8)
        if Node.mode == 'wrong_network':
            info['network_id'] = 1
        if Node.mode == 'bad_network':
            info['network_id'] = '0'
        payload = json.dumps(dict(result=dict(status='success', info=info))).encode()
        if Node.mode == 'bad_json':
            payload = b'{bad'
        self.send_response(200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


def main():
    node = ThreadingHTTPServer(('127.0.0.1', 0), Node)
    thread = threading.Thread(target=node.serve_forever, daemon=True)
    thread.start()
    rpc = f'http://127.0.0.1:{node.server_port}'
    try:
        with tempfile.TemporaryDirectory(prefix='xl-status-') as tmp:
            for mode in ['ok', 'wrong_network', 'bad_network', 'bad_json', 'slow']:
                Node.mode = mode
                Node.count = 0
                with backend(Path(tmp) / mode, rpc) as (url, _):
                    health = request(url, '/health')
                    assert set(health) == {'service', 'network_id', 'pid', 'state_backend'}
                    start = time.monotonic()
                    with ThreadPoolExecutor(max_workers=4) as pool:
                        pending = [pool.submit(request, url, '/status') for _ in range(3)]
                        if mode == 'slow':
                            assert Node.entered.wait(2)
                            before = time.monotonic()
                            assert request(url, '/health') == health
                            assert time.monotonic() - before < 1
                        observations = [p.result(timeout=6) for p in pending]
                    elapsed = time.monotonic() - start
                    assert Node.count == 1, (mode, Node.count)
                    assert observations[0] == observations[1] == observations[2]
                    status = observations[0]['xrpld']
                    assert int(status['observed_at_unix']) > 0
                    if mode == 'ok':
                        assert status['reachable'] and status['network_compatible']
                        assert status['validated_ledger']['seq'] == 201
                        assert status['network_id'] is None  # Mainnet effective default
                        time.sleep(5.1)
                        request(url, '/status')
                        assert Node.count == 2
                    elif mode == 'wrong_network':
                        assert status['reachable'] and status['network_compatible'] is False
                        assert status['error']
                    else:
                        assert status['error'] and status['network_compatible'] is None
                    if mode == 'slow':
                        assert 2.7 < elapsed < 4.5, elapsed
                        assert request(url, '/status') == observations[0]
                        assert Node.count == 1
                        Node.release.set()
            Node.mode = 'ok'
            with backend(Path(tmp) / 'non-mainnet', rpc, network=1) as (url, _):
                assert request(url, '/status')['xrpld']['network_compatible'] is False
            with backend(Path(tmp) / 'unreachable', f'http://127.0.0.1:{free_port()}') as (url, _):
                status = request(url, '/status')['xrpld']
                assert not status['reachable'] and status['error']
                assert request(url, '/health')['service'] == 'XLB'
    finally:
        Node.release.set()
        node.shutdown()
        node.server_close()
    print('PASS status: one bounded shared probe, cache expiry, malformed responses, network checks and independent health')


if __name__ == '__main__':
    main()
