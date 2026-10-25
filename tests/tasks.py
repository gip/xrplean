"""Backend-owned acquisitions survive observers, retain failures, and resume exact targets."""
from http.server import ThreadingHTTPServer
from pathlib import Path
import io
import json
import os
import signal
import subprocess
import tempfile
import threading
import time

from acquisition import ENTRIES, Node
from integration import ROOT, XLC, backend, cli, request


class TaskNode(Node):
    latest = 200
    fail_page = False

    def do_POST(self):
        raw = self.rfile.read(int(self.headers['Content-Length']))
        posted = json.loads(raw)
        method, params = posted['method'], posted['params'][0]
        if method == 'server_info':
            type(self).calls.append((method, params))
            payload = json.dumps({'result': {'status': 'success', 'info': {
                'network_id': 0, 'validated_ledger': {'seq': type(self).latest}}}}).encode()
            self.send_response(200)
        elif method == 'ledger_data' and params.get('marker') == '1' and type(self).fail_page:
            type(self).calls.append((method, params))
            payload = b'requested ledger is unavailable'
            self.send_response(404)
        else:
            self.rfile = io.BytesIO(raw)
            return super().do_POST()
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def wait_task(url, task_id, expected='succeeded'):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        task = request(url, '/tasks/' + task_id)
        if task['status'] not in ('queued', 'running'):
            assert task['status'] == expected, task
            return task
        time.sleep(.05)
    raise AssertionError(f'task timed out: {task}')


def pause_page():
    paused, release = threading.Event(), threading.Event()
    def gate(page):
        if page == 1:
            paused.set()
            assert release.wait(30), 'test did not release the paused RPC'
    TaskNode.state_page_gate = gate
    return paused, release


def events(url, task_id, after_seq=0):
    import urllib.request
    req = urllib.request.Request(url + '/tasks/' + task_id + '/stream',
                                 data=json.dumps({'after_seq': after_seq}).encode(),
                                 headers={'Content-Type': 'application/json'})
    return urllib.request.urlopen(req, timeout=15)


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), TaskNode)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    rpc = f'http://127.0.0.1:{server.server_port}'
    releases = []
    try:
        with tempfile.TemporaryDirectory(prefix='xl-tasks-') as tmp:
            data = Path(tmp) / 'data'
            with backend(data, rpc) as (url, _):
                # Reproduce the reported command through the real entry point.
                latest = subprocess.run([str(ROOT / 'xl'), 'ledger', 'get', '--bundle', 'aaa-mainnet',
                                         '--index', 'latest', '--backend', url], cwd=ROOT,
                                        capture_output=True, text=True, timeout=60)
                assert latest.returncode == 0, latest.stderr
                result = json.loads(latest.stdout)
                assert result[0]['ledger_index'] == 200 and result[0]['state_downloaded'] is False
                task_id = cli(url, 'task', 'show', '-b', 'aaa-mainnet')[0]['task_id']
                detail = cli(url, 'task', 'show', '--id', task_id)
                assert detail['request']['from'] == 'latest' and detail['kind'] == 'fetch'
                assert detail['resolved_request']['from'] == detail['resolved_request']['to'] == 200
                TaskNode.latest = 201
                assert cli(url, 'ledger', 'get', '-b', 'aaa-mainnet', '-i', 'latest', '--no-progress')[0]['ledger_index'] == 201
                TaskNode.latest = 200

                paused, release = pause_page()
                releases.append(release)
                task = cli(url, 'bundle', 'new', '-b', 'detached', '-i', 'latest', '--detach')
                task_id = task['task_id']
                assert task['status'] in ('queued', 'running')
                assert paused.wait(10)
                running = cli(url, 'task', 'show', '--id', task_id)
                assert running['bundle'] == 'detached' and running['status'] == 'running'
                assert running['progress']['pages'] == 1
                assert running['resolved_request']['from'] == 200
                assert cli(url, 'task', 'show', '-b', 'detached')[0]['task_id'] == task_id
                assert cli(url, 'task', 'show', '-b', 'detached', '--running')[0]['task_id'] == task_id
                assert cli(url, 'task', 'show', '-b', 'detached', '--done') == []
                assert cli(url, 'task', 'show', '-b', 'default') == []
                assert 'task not found' in cli(url, 'task', 'show', '--id', task_id, '-b', 'default', success=False)
                assert 'already in use' in cli(url, 'bundle', 'new', '-b', 'detached', '-i', '200', '--detach', success=False)
                # Attach and abandon the observer while acquisition is still paused.
                with events(url, task_id) as response:
                    assert json.loads(response.readline())['event'] == 'progress'
                assert request(url, '/health')['service'] == 'XLB'
                release.set()
                finished = wait_task(url, task_id)
                assert cli(url, 'task', 'show', '-b', 'detached', '--running') == []
                assert cli(url, 'task', 'show', '-b', 'detached', '--done')[0]['task_id'] == task_id
                assert finished['result'][0]['ledger_index'] == 200
                assert cli(url, 'task', 'wait', '--id', task_id, '--no-progress') == finished['result']
                with events(url, task_id) as response:
                    history = [json.loads(line) for line in response if line.strip()]
                assert history[-1]['event'] == 'result'
                assert all(e['task_id'] == task_id for e in history)
                assert [e['event_seq'] for e in history] == sorted(e['event_seq'] for e in history)
                with events(url, task_id, history[-2]['event_seq']) as response:
                    assert [json.loads(line)['event'] for line in response if line.strip()] == ['result']
                with events(url, task_id, history[-1]['event_seq']) as response:
                    last = json.loads(response.readline())
                    assert last['event'] == 'result' and last['task_id'] == task_id

                # The ordinary foreground CLI can exit without cancelling XLB's work.
                paused, release = pause_page()
                releases.append(release)
                child = subprocess.Popen([str(XLC), '--backend', url, 'bundle', 'new',
                                          '-b', 'foreground', '-i', '200'], cwd=ROOT,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                         start_new_session=True, text=True)
                try:
                    assert paused.wait(10)
                    task_id = cli(url, 'task', 'show', '-b', 'foreground')[0]['task_id']
                    os.killpg(child.pid, signal.SIGTERM)
                    child.communicate(timeout=5)
                    assert cli(url, 'task', 'show', '--id', task_id)['status'] == 'running'
                    release.set()
                    wait_task(url, task_id)
                finally:
                    release.set()
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.communicate()

                # Failed tasks remain visible. Retry freezes latest at the original target.
                TaskNode.state_page_gate = None
                TaskNode.fail_page = True
                failed = cli(url, 'ledger', 'get', '-b', 'outage', '-i', 'latest', '--state', '--detach')
                failed = wait_task(url, failed['task_id'], 'failed')
                assert failed['request']['from'] == 'latest' and failed['resolved_request']['from'] == 200
                assert 'status 404' in failed['error'] and failed['progress']['pages'] == 1
                TaskNode.fail_page = False
                TaskNode.latest = 201
                before = len(TaskNode.calls)
                retry = cli(url, 'task', 'retry', '--id', failed['task_id'])
                resumed = wait_task(url, retry['task_id'])
                assert retry['retry_of'] == failed['task_id']
                assert resumed['result'][0]['ledger_index'] == 200
                assert cli(url, 'task', 'show', '--id', failed['task_id'])['status'] == 'failed'
                page_calls = [p for m, p in TaskNode.calls[before:] if m == 'ledger_data']
                assert [p.get('marker') for p in page_calls] == ['1', '2', '3']
                assert all(p['ledger_hash'] == Node.hash200 for p in page_calls)

            # A hard restart retains task history and marks the interrupted owner honestly.
            data = Path(tmp) / 'crash'
            TaskNode.latest = 200
            paused, release = pause_page()
            releases.append(release)
            with backend(data, rpc, expected_exit=-signal.SIGKILL) as (url, process):
                crashed = cli(url, 'ledger', 'get', '-b', 'crash', '-i', 'latest', '--state', '--detach')
                assert paused.wait(10)
                queued = cli(url, 'ledger', 'get', '--index', 201, '-b', 'queued', '--detach')
                assert queued['status'] == 'queued'
                process.kill()
                process.wait(5)
                release.set()
            TaskNode.state_page_gate = None
            TaskNode.latest = 201
            with backend(data, rpc) as (url, _):
                assert cli(url, 'task', 'show', '--id', crashed['task_id'])['status'] == 'interrupted'
                wait_task(url, queued['task_id'])
                retry = cli(url, 'task', 'retry', '--id', crashed['task_id'])
                resumed = wait_task(url, retry['task_id'])
                assert resumed['result'][0]['ledger_index'] == 200
                assert resumed['progress']['entries'] == len(ENTRIES)
                assert cli(url, 'jobs', '-b', 'crash') == []
                assert cli(url, 'ledgers', '-b', 'crash')[0]['trust'] == 'untrusted'
        print('PASS detached and killed CLI, abandoned observer, task history/scoping/reattach, failure/retry, pinned latest, crash recovery, queued restart, trust isolation')
    finally:
        for release in releases:
            release.set()
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    main()
