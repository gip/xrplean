"""CLI routing and validation against a loopback HTTP recorder, without proof claims."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import tempfile
import threading

from integration import cli

HASH = 'AB' * 32
OTHER = 'CD' * 32


class Recorder(BaseHTTPRequestHandler):
    calls = []

    def log_message(self, *args):
        pass

    def respond(self, method):
        body = None
        if method == 'POST':
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        type(self).calls.append((method, self.path, body))
        if self.path.endswith('/ledgers') and method == 'GET':
            value = [dict(ledger_index='200', ledger_hash=HASH),
                     dict(ledger_index='200', ledger_hash=OTHER),
                     dict(ledger_index='201', ledger_hash=HASH)]
        elif self.path.endswith('/tasks') and method == 'GET':
            value = [dict(task_id='7', status='running'), dict(task_id='8', status='failed')]
        elif self.path.endswith('/tasks') and method == 'POST':
            value = dict(task_id='7', status='queued')
        elif self.path.endswith('/jobs') and method == 'POST':
            value = dict(job_id='9', status='queued')
        elif self.path.endswith('/ledgers') and method == 'POST':
            self.send_response(204)
            self.end_headers()
            return
        else:
            value = dict(method=method, path=self.path, body=body)
        payload = json.dumps(value).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self.respond('GET')

    def do_POST(self):
        self.respond('POST')


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Recorder)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f'http://127.0.0.1:{server.server_port}'
    try:
        # Unselected acquisition history is network-wide; job history is bundle-scoped.
        assert cli(url, 'job', 'show')['path'] == '/bundles/default/jobs'
        assert cli(url, 'job', 'show', '--id', 9, '-b', 'alpha')['path'] == '/bundles/alpha/jobs/9'
        assert len(cli(url, 'task', 'show')) == 2
        assert Recorder.calls[-1][1] == '/tasks'
        assert cli(url, 'task', 'show', '--bundle', 'alpha', '--running') == [dict(task_id='7', status='running')]
        assert Recorder.calls[-1][1] == '/bundles/alpha/tasks'
        assert cli(url, 'task', 'show', '--done') == [dict(task_id='8', status='failed')]
        for action, suffix in [('show', ''), ('wait', '/wait'), ('retry', '/retry'), ('cancel', '/cancel')]:
            args = ['task', action, '--id', 7, '--bundle', 'alpha']
            if action == 'wait':
                args += ['--no-progress']
            assert cli(url, *args)['path'] == '/bundles/alpha/tasks/7' + suffix
        assert cli(url, 'job', 'cancel', '--id', 9, '-b', 'alpha')['path'] == '/bundles/alpha/jobs/9/cancel'
        assert Recorder.calls[-1] == ('POST', '/bundles/alpha/jobs/9/cancel', {})
        assert cli(url, 'bundle', 'show')['path'] == '/bundles'
        assert cli(url, 'bundle', 'show', '--bundle', 'alpha')['path'] == '/bundles/alpha/state/info'
        assert cli(url, 'export', 'show', '-b', 'alpha')['path'] == '/bundles/alpha/exports'
        # A selected index retains every fork; hash filtering selects one identity.
        assert len(cli(url, 'ledger', 'show', '--index', 200)) == 2
        assert cli(url, 'ledger', 'show', '--index', 200, '--hash', HASH.lower()) == [dict(ledger_index='200', ledger_hash=HASH)]
        assert cli(url, 'ledger', 'show', '--index', 202) == []
        task = cli(url, 'ledger', 'get', '--bundle', 'alpha', '--index', '200:201', '--state', '--transport', 'peer', '--detach')
        assert task['task_id'] == '7'
        assert Recorder.calls[-1] == ('POST', '/bundles/alpha/tasks', dict(kind='fetch', request={
            'from': 200, 'to': 201, 'state': True, 'transport': 'peer'}))
        cli(url, 'ledger', 'get', '-i', 200, '--hash', HASH, '--no-progress')
        assert Recorder.calls[-2][2] == dict(kind='fetch', request={'from': 200, 'to': 200, 'state': False, 'ledger_hash': HASH})
        assert Recorder.calls[-1] == ('POST', '/bundles/default/tasks/7/wait', {})
        cli(url, 'ledger', 'get', '--bundle', 'aaa-mainnet', '--index', 'latest', '--detach')
        assert Recorder.calls[-1] == ('POST', '/bundles/aaa-mainnet/tasks', dict(kind='fetch', request={'from': 'latest', 'state': False}))
        cli(url, 'ledger', 'get', '-i', 'latest', '--state', '--hash', HASH, '--no-progress')
        assert Recorder.calls[-2][2] == dict(kind='fetch', request={'from': 'latest', 'state': True, 'ledger_hash': HASH})
        for action, selector in [('new', 'latest'), ('update', ':205')]:
            cli(url, 'bundle', action, '-b', 'alpha', '-i', selector, '--transport', 'rpc', '--detach')
            assert Recorder.calls[-1] == ('POST', '/bundles/alpha/tasks', dict(kind='state_' + action, request={'index': selector, 'transport': 'rpc'}))
        cli(url, 'ledger', 'verify', '--index', '200:201', '--checks', 'merkle,payments', '-b', 'alpha')
        assert Recorder.calls[-1] == ('POST', '/bundles/alpha/jobs', {'from': 200, 'to': 201, 'checks': ['merkle', 'payments']})
        cli(url, 'ledger', 'verify', '--index', 200, '--checks', 'merkle', '--export-id', 3)
        assert Recorder.calls[-1][2]['export_id'] == 3
        cli(url, 'ledger', 'trust', '--index', 200, '--hash', HASH, '--reason', "operator's checkpoint")
        assert Recorder.calls[-1] == ('POST', '/bundles/default/trust', dict(ledger_index=200, ledger_hash=HASH, reason="operator's checkpoint"))
        with tempfile.TemporaryDirectory(prefix='xl-cli-') as tmp:
            path = Path(tmp) / 'input with spaces.json'
            payload = dict(nodes=[dict(hash=HASH, wire='00')])
            path.write_text(json.dumps(payload))
            assert cli(url, 'ledger', 'receive', '--file', path) is None
            assert Recorder.calls[-1] == ('POST', '/bundles/default/ledgers', payload)
            cli(url, 'state', 'import', '--index', 200, '--hash', HASH, '--file', path)
            assert Recorder.calls[-1] == ('POST', '/bundles/default/state', dict(ledger_index=200, ledger_hash=HASH, **payload))
        # Compatibility aliases go through the same dispatcher.
        aliases = [
            (['fetch', 200, 201, '--detach'], ['ledger', 'get', '--index', '200:201', '--detach']),
            (['verify', 200, '--checks', 'merkle'], ['ledger', 'verify', '--index', 200, '--checks', 'merkle']),
            (['jobs'], ['job', 'show']), (['job', 9], ['job', 'show', '--id', 9]),
            (['tasks'], ['task', 'show']), (['task', 7], ['task', 'show', '--id', 7]),
            (['task', 'retry', 7], ['task', 'retry', '--id', 7]),
            (['task', 'cancel', 7], ['task', 'cancel', '--id', 7]),
            (['job', 'cancel', 9], ['job', 'cancel', '--id', 9]),
            (['state', 'new', '-i', 200, '--detach'], ['bundle', 'new', '-i', 200, '--detach']),
            (['state', 'info'], ['bundle', 'show', '-b', 'default']),
            (['state', 'list'], ['bundle', 'show']),
            (['ledgers'], ['ledger', 'show']), (['exports'], ['export', 'show']),
        ]
        for old, new in aliases:
            cli(url, *old)
            before = Recorder.calls[-1]
            cli(url, *new)
            assert Recorder.calls[-1] == before, (old, new)
        # Invalid inputs cannot create a task, trust anchor, or verification job.
        invalid = [
            ['ledger', 'get'], ['ledger', 'get', '--index'],
            ['ledger', 'get', '--index', '--bundle', 'alpha'],
            ['ledger', 'get', '--index', '201:200'], ['ledger', 'get', '--index', '1:10001'],
            ['ledger', 'get', '--index', 0], ['ledger', 'get', '--index', 'latest:201'], ['ledger', 'get', '--index', ':latest'],
            ['ledger', 'get', '--index', 200, '-i', 201],
            ['ledger', 'get', '--index', 200, '--state', '--state'],
            ['ledger', 'get', '--index', 200, '--transport', 'bogus'],
            ['ledger', 'get', '--index', '200:201', '--hash', HASH],
            ['ledger', 'get', '--index', 200, '--bundle', 'a', '-b', 'b'],
            ['ledger', 'get', '--index', 200, '--unknown'],
            ['ledger', 'get', '--index', 200, '--bundle', '../escape'],
            ['ledger', 'get', '--index', 200, '--backend', url],  # duplicate global
            ['ledger', 'verify', '--index', 200, '--checks', 'consensus'],
            ['ledger', 'verify', '--index', 200, '--checks', 'merkle', '--hash', HASH, '--export-id', 3],
            ['ledger', 'verify', '--index', '200:201', '--checks', 'merkle', '--export-id', 3],
            ['ledger', 'trust', '--index', 200],
            ['task', 'wait'], ['job', 'show', '--id', 'abc'],
            ['job', 'cancel'], ['job', 'cancel', '--id', 'abc'],
            ['task', 'show', '--running', '--done'], ['task', 'show', '--id', 7, '--running'],
            ['bundle', 'update'], ['bundle', 'show', '--index', 200],
        ]
        before = len(Recorder.calls)
        for args in invalid:
            cli(url, *args, success=False)
            assert len(Recorder.calls) == before, args
        print('PASS noun/action routing, named selectors, bundle scoping, fork filtering, compatibility aliases, and validation before HTTP')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    main()
