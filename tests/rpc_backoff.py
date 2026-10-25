"""Capped RPC retry delays, exact page pinning, async HTTP framing, and prompt shutdown."""
from http.server import ThreadingHTTPServer
from pathlib import Path
import io
import json
import os
import signal
import tempfile
import threading
import time

from acquisition import Node
from integration import backend, cli, free_port, request
from tasks import TaskNode, events, wait_task


class RetryNode(TaskNode):
    protocol_version = 'HTTP/1.1'
    failures = 0
    failure_mode = '503'
    page_times = []
    framing = 'length'

    def do_POST(self):
        raw = self.rfile.read(int(self.headers['Content-Length']))
        posted = json.loads(raw)
        method, params = posted['method'], posted['params'][0]
        if method == 'ledger_data' and params.get('marker') == '1':
            type(self).page_times.append((time.monotonic(), dict(params)))
            if type(self).failures:
                type(self).failures -= 1
                if self.failure_mode == 'disconnect':
                    self.connection.close()
                    return
                code = int(self.failure_mode) if self.failure_mode != 'malformed' else 200
                self.send_response(code)
                payload = b'invalid JSON' if self.failure_mode == 'malformed' else b'upstream unavailable'
                self.send_header('Content-Type', 'application/json')
                self.send_header('Connection', 'close')
                if self.framing == 'length':
                    self.send_header('Content-Length', str(len(payload)))
                elif self.framing == 'chunked':
                    self.send_header('Transfer-Encoding', 'chunked')
                self.end_headers()
                if self.framing == 'chunked':
                    self.wfile.write(f'{len(payload):X}\r\n'.encode() + payload + b'\r\n0\r\n\r\n')
                else:
                    self.wfile.write(payload)
                return
        self.rfile = io.BytesIO(raw)
        if self.framing == 'length':
            return super().do_POST()
        # Reframe a normal mock reply without changing its XRPL payload.
        output = self.wfile
        buffered = io.BytesIO()
        self.wfile = buffered
        try:
            super().do_POST()
        finally:
            self.wfile = output
        _, payload = buffered.getvalue().split(b'\r\n\r\n', 1)
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Connection', 'close')
        if self.framing == 'chunked':
            self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        if self.framing == 'chunked':
            for start in range(0, len(payload), 37):
                chunk = payload[start:start+37]
                output.write(f'{len(chunk):X}\r\n'.encode() + chunk + b'\r\n')
            output.write(b'0\r\n\r\n')
        else:
            output.write(payload)


def submit(url, bundle):
    return cli(url, 'state', 'new', '-b', bundle, '-i', '200', '--detach')['task_id']


def history(url, task_id):
    with events(url, task_id) as response:
        return [json.loads(line) for line in response if line.strip()]


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), RetryNode)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    rpc = f'http://127.0.0.1:{server.server_port}'
    try:
        with tempfile.TemporaryDirectory(prefix='xl-rpc-backoff-') as tmp:
            folder = Path(tmp)
            binaries = folder / 'bin'
            binaries.mkdir()
            fake_curl = binaries / 'curl'
            fake_curl.write_text('#!/bin/sh\nexit 93\n')
            fake_curl.chmod(0o755)
            with backend(folder / 'data', rpc, rpc_backoff_max=2,
                         env={'PATH': str(binaries) + os.pathsep + os.environ['PATH']}) as (url, _):
                RetryNode.failures = 3
                RetryNode.page_times = []
                task_id = submit(url, 'retry')
                wait_task(url, task_id)
                retried = [e for e in history(url, task_id) if e.get('phase') == 'rpc_retry']
                assert [e['retry_attempt'] for e in retried] == [1, 2, 3]
                assert [e['retry_delay_ms'] for e in retried] == [1000, 2000, 2000]
                assert all(e['pages'] == e['entries'] == 1 for e in retried)
                times = RetryNode.page_times
                assert len(times) == 4
                assert all(p['ledger_hash'] == Node.hash200 and p['marker'] == '1' for _, p in times)
                for (before, _), (after, _), minimum in zip(times, times[1:], [1, 2, 2]):
                    assert after-before >= minimum-.05, times
                assert request(url, '/health')['service'] == 'XLB'

                # A mid-response connection closure also retries the same pinned page.
                RetryNode.failure_mode = 'disconnect'
                RetryNode.failures = 1
                task_id = submit(url, 'disconnect')
                wait_task(url, task_id)
                assert len([e for e in history(url, task_id) if e.get('phase') == 'rpc_retry']) == 1

                # Permanent HTTP/JSON failures must still fail immediately.
                for mode in ('404', 'malformed'):
                    RetryNode.failure_mode = mode
                    RetryNode.failures = 9
                    RetryNode.page_times = []
                    task_id = submit(url, 'permanent_' + mode)
                    wait_task(url, task_id, 'failed')
                    assert len(RetryNode.page_times) == 1
                    assert not any(e.get('phase') == 'rpc_retry' for e in history(url, task_id))

                RetryNode.failures = 0
                for framing in ('chunked', 'close'):
                    RetryNode.framing = framing
                    wait_task(url, submit(url, framing))
                    RetryNode.failure_mode = 'malformed'
                    RetryNode.failures = 9
                    RetryNode.page_times = []
                    task_id = submit(url, framing + '_malformed')
                    wait_task(url, task_id, 'failed')
                    assert len(RetryNode.page_times) == 1
                    RetryNode.failures = 0
                RetryNode.framing = 'length'

            with backend(folder / 'hostname', f'http://localhost:{server.server_port}') as (url, _):
                wait_task(url, submit(url, 'hostname'))

            # Outages do not exhaust retries, even beyond the former eight-retry
            # limit. The same task automatically finishes its pinned page on recovery.
            with backend(folder / 'indefinite', rpc, rpc_backoff_max=1) as (url, _):
                RetryNode.failure_mode = '503'
                RetryNode.failures = 1000
                RetryNode.page_times = []
                before = len(RetryNode.calls)
                task_id = submit(url, 'indefinite')
                deadline = time.monotonic()+20
                while time.monotonic() < deadline:
                    task = cli(url, 'task', task_id)
                    assert task['status'] in ('queued', 'running'), task
                    if task['progress'] and task['progress'].get('retry_attempt', 0) >= 10:
                        break
                    time.sleep(.05)
                else:
                    raise AssertionError(task)
                assert task['status'] == 'running' and task['progress']['pages'] == 1
                assert task['progress']['retry_delay_ms'] == 1000
                assert request(url, '/health')['service'] == 'XLB'
                RetryNode.failures = 0
                resumed = wait_task(url, task_id)
                assert resumed['task_id'] == task_id and resumed['result'][0]['ledger_hash'] == Node.hash200
                retried = [e for e in history(url, task_id) if e.get('phase') == 'rpc_retry']
                assert len(retried) >= 10
                assert all(e['retry_delay_ms'] == 1000 for e in retried)
                assert all(e['pages'] == e['entries'] == 1 for e in retried)
                assert all(p['ledger_hash'] == Node.hash200 and p['marker'] == '1'
                           for _, p in RetryNode.page_times)
                calls = RetryNode.calls[before:]
                assert sum(m == 'server_info' for m, _ in calls) == 1
                assert sum(m == 'ledger' for m, _ in calls) == 1

            # A genuinely absent RPC listener can return without requiring a task retry.
            port = free_port()
            with backend(folder / 'returned', f'http://127.0.0.1:{port}', rpc_backoff_max=1) as (url, _):
                task_id = submit(url, 'returned')
                deadline = time.monotonic()+10
                while time.monotonic() < deadline:
                    task = cli(url, 'task', task_id)
                    assert task['status'] in ('queued', 'running'), task
                    if task['progress'] and task['progress'].get('retry_attempt', 0) >= 2:
                        break
                    time.sleep(.05)
                else:
                    raise AssertionError(task)
                returned = ThreadingHTTPServer(('127.0.0.1', port), RetryNode)
                returned_thread = threading.Thread(target=returned.serve_forever, daemon=True)
                returned_thread.start()
                try:
                    assert wait_task(url, task_id)['result'][0]['ledger_hash'] == Node.hash200
                finally:
                    returned.shutdown()
                    returned.server_close()
                    returned_thread.join()

            # Connection refusal backs off while health/task requests remain responsive.
            stopped = folder / 'stopped'
            with backend(stopped, f'http://127.0.0.1:{free_port()}', rpc_backoff_max=30) as (url, process):
                task_id = submit(url, 'offline')
                deadline = time.monotonic()+10
                while time.monotonic() < deadline:
                    task = cli(url, 'task', task_id)
                    if task['progress'] and task['progress'].get('retry_attempt') == 2:
                        break
                    time.sleep(.05)
                else:
                    raise AssertionError(task)
                assert task['status'] == 'running' and task['progress']['retry_delay_ms'] == 2000
                assert request(url, '/health')['service'] == 'XLB'
                before = time.monotonic()
                process.send_signal(signal.SIGTERM)
                process.wait(5)
                assert time.monotonic()-before < 3
            with backend(stopped, rpc) as (url, _):
                assert cli(url, 'task', task_id)['status'] == 'interrupted'
        print('PASS capped exponential retries, indefinite outage recovery, same task/page identity, returning RPC listener, permanent failures, disconnected RPC, native HTTP length/chunked/EOF, health responsiveness, shutdown during backoff')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    main()
