"""Live progress, error propagation, clean stdout, terminal rendering, and NuDB storage."""
from http.server import ThreadingHTTPServer
from pathlib import Path
import errno
import json
import os
import pty
import queue as queues
import select
import subprocess
import tempfile
import threading
import time
import urllib.request
from integration import ROOT, XLC, backend, cli, request
from acquisition import Node, ENTRIES


class ProgressNode(Node):
    pass


def stream(url, body):
    req = urllib.request.Request(url + '/fetch/stream', data=json.dumps(body).encode(),
                                 headers={'Content-Type': 'application/json'})
    return urllib.request.urlopen(req, timeout=15)


def terminal_cli(url):
    master, slave = pty.openpty()
    child = subprocess.Popen([str(XLC), '--backend', url, 'ledger', 'get', '--index', '200', '--state'],
                             cwd=ROOT, stdout=subprocess.PIPE, stderr=slave, text=True)
    os.close(slave)
    terminal = bytearray()
    deadline = time.monotonic() + 30
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], .1)
            if ready:
                try:
                    block = os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not block:
                    break
                terminal.extend(block)
            elif child.poll() is not None:
                break
        else:
            raise AssertionError('terminal progress timed out')
        output = child.communicate(timeout=5)[0]
        assert child.returncode == 0, terminal.decode()
        assert json.loads(output)[0]['state_backend'] == 'nudb'
        text = terminal.decode()
        assert '\x1b[2K' in text and '\x1b[2A' in text
        assert '100.0% keyspace' in text and 'resuming saved state' in text and 'stored' in text
        assert 'RPC ' in text and 'local ' in text
    finally:
        os.close(master)
        if child.poll() is None:
            child.kill()
            child.wait()


def main():
    paused, release = threading.Event(), threading.Event()
    def gate(page):
        if page == 1:
            paused.set()
            assert release.wait(10), 'progress consumer did not release the next state page'
    ProgressNode.state_page_gate = gate
    server = ThreadingHTTPServer(('127.0.0.1', 0), ProgressNode)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    rpc = f'http://127.0.0.1:{server.server_port}'
    try:
        with tempfile.TemporaryDirectory(prefix='xl-progress-') as tmp:
            with backend(Path(tmp) / 'data', rpc) as (url, _):
                assert request(url, '/health')['state_backend'] == 'nudb'
                events = []
                with stream(url, {'from': 200, 'state': True}) as response:
                    assert response.headers['Content-Type'] == 'application/x-ndjson'
                    while True:
                        event = json.loads(response.readline())
                        events.append(event)
                        if event.get('entries', 0) > 0:
                            break
                    assert paused.wait(5)
                    assert not any(e.get('phase') == 'complete' for e in events)
                    # The first page is visible while the next page is blocked.
                    assert events[-1]['entries'] == 1
                    assert request(url, '/health')['service'] == 'XLB'
                    release.set()
                    events.extend(json.loads(line) for line in response if line.strip())
                ProgressNode.state_page_gate = None
                progress = [e for e in events if e['event'] == 'progress']
                assert events[-1]['event'] == 'result'
                assert events[-1]['data'][0]['state_backend'] == 'nudb'
                assert progress[-1]['phase'] == 'complete'
                assert progress[-1]['entries'] == len(ENTRIES)
                assert progress[-1]['pages'] == len(ENTRIES)
                assert progress[-1]['state_bytes'] == sum(len(e['data'])//2 for e in ENTRIES)
                assert all(e['keyspace_permille'] < 1000 for e in progress if e['phase'] != 'complete')
                assert any(e['phase'] == 'checking_root' for e in progress)
                assert all('rpc_ms' in e and 'local_ms' in e for e in progress)
                # CLI output stays valid JSON, stderr has useful plain progress when redirected.
                result = subprocess.run([str(XLC), '--backend', url, 'ledger', 'get', '--index', '200', '--state'],
                                        cwd=ROOT, capture_output=True, text=True, timeout=30)
                assert result.returncode == 0, result.stderr
                assert json.loads(result.stdout)[0]['state_backend'] == 'nudb'
                assert f'task show --backend {url} --bundle default --id ' in result.stderr
                assert 'entries' in result.stderr and 'RPC ' in result.stderr
                assert '\x1b[' not in result.stderr and '\r' not in result.stderr
                assert '100.0% keyspace' in result.stderr
                silent = subprocess.run([str(XLC), '--backend', url, 'ledger', 'get', '--index', '200', '--state', '--no-progress'],
                                        cwd=ROOT, capture_output=True, text=True, timeout=30)
                assert silent.returncode == 0 and silent.stderr == ''
                assert json.loads(silent.stdout)[0]['state_backend'] == 'nudb'
                terminal_cli(url)
            with backend(Path(tmp) / 'bad-data', rpc) as (url, _):
                # Root failure emits an error, never a completed snapshot or a 100% bar.
                ProgressNode.mode = 'bad_blob'
                with stream(url, {'from': 200, 'state': True}) as response:
                    failed = [json.loads(line) for line in response if line.strip()]
                assert failed[-1]['event'] == 'error'
                assert 'does not match ledger root' in failed[-1]['error']
                assert not any(e.get('phase') == 'complete' or e['event'] == 'result' for e in failed)
                bad = subprocess.run([str(XLC), '--backend', url, 'ledger', 'get', '--index', '200', '--state'],
                                     cwd=ROOT, capture_output=True, text=True, timeout=30)
                assert bad.returncode == 1 and bad.stdout == ''
                assert 'does not match ledger root' in bad.stderr
                assert '100.0% keyspace' not in bad.stderr
                ProgressNode.mode = 'good'
                assert [r['ledger_index'] for r in cli(url, 'fetch', 200, 201)] == [200, 201]
        print('PASS streaming before completion, TTY bar, plain stderr progress, JSON stdout, no-progress, root failure, NuDB, and timing counters')
    finally:
        release.set()
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    main()
