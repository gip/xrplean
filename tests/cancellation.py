"""Explicit cancellation preserves history/checkpoints and releases only its own task."""
from http.server import ThreadingHTTPServer
from pathlib import Path
import json
import sqlite3
import tempfile
import threading
import time

from acquisition import Node
from integration import backend, cli, request
from rpc_backoff import RetryNode
from tasks import TaskNode, events, pause_page, wait_task


def history(url, task_id):
    with events(url, task_id) as response:
        return [json.loads(line) for line in response if line.strip()]


def wait_progress(url, task_id, predicate):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        task = request(url, '/tasks/' + task_id)
        if predicate(task):
            return task
        time.sleep(.02)
    raise AssertionError(task)


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), TaskNode)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    rpc = f'http://127.0.0.1:{server.server_port}'
    release = None
    try:
        with tempfile.TemporaryDirectory(prefix='xl-cancellation-') as tmp:
            data = Path(tmp) / 'data'
            with backend(data, rpc) as (url, _):
                paused, release = pause_page()
                running = cli(url, 'bundle', 'new', '-b', 'running', '-i', 'latest', '--detach')
                task_id = running['task_id']
                assert paused.wait(10)
                queued = cli(url, 'ledger', 'get', '-b', 'queued', '-i', 201, '--detach')
                queued_id = queued['task_id']
                assert queued['status'] == 'queued'
                # Wrong-bundle requests must not cancel another bundle's work.
                assert 'task not found' in cli(url, 'task', 'cancel', '-b', 'default', '--id', task_id, success=False)
                assert not request(url, '/tasks/' + task_id)['cancel_requested']
                assert 'task not found' in request(url, '/tasks/99999/cancel', {}, 422)['error']

                cancelled_queue = cli(url, 'task', 'cancel', '--id', queued_id)
                assert cancelled_queue['status'] == 'cancelled' and cancelled_queue['started_at'] == ''
                assert cancelled_queue['cancel_requested'] and cancelled_queue['finished_at']
                assert cli(url, 'task', 'cancel', queued_id) == cancelled_queue
                assert len(history(url, queued_id)) == 1
                assert 'cancelled' in cli(url, 'task', 'wait', '--id', queued_id, '--no-progress', success=False)
                assert request(url, '/tasks/' + task_id)['status'] == 'running'
                # The HTTP reply is still blocked: cancellation must close that RPC itself.
                next_task = cli(url, 'ledger', 'get', '-b', 'next', '-i', 201, '--detach')
                started = time.monotonic()
                accepted = cli(url, 'task', 'cancel', '-b', 'running', '--id', task_id)
                assert accepted['cancel_requested']
                cancelled = wait_task(url, task_id, 'cancelled')
                assert time.monotonic() - started < 3
                assert cancelled['result'] is None and cancelled['progress']['pages'] == 1
                assert cancelled['resolved_request']['from'] == 200
                assert cancelled['finished_at'] and 'cancelled' in cancelled['error']
                assert cli(url, 'task', 'cancel', '--id', task_id) == cancelled
                journal = history(url, task_id)
                assert journal[-1]['event'] == 'error' and 'cancelled' in journal[-1]['error']
                assert sum(e['event'] == 'error' for e in journal) == 1
                assert not any(e['event'] == 'result' for e in journal)
                assert 'cancelled' in cli(url, 'task', 'wait', '--id', task_id, success=False)
                assert 'cancelled' in cli(url, 'task', 'wait', '--id', task_id, '--no-progress', success=False)
                assert cli(url, 'task', 'show', '-b', 'running', '--running') == []
                assert cli(url, 'task', 'show', '-b', 'running', '--done')[0]['status'] == 'cancelled'
                following = wait_task(url, next_task['task_id'])
                assert cli(url, 'task', 'cancel', '--id', following['task_id']) == following
                assert request(url, '/health')['service'] == 'XLB'
                # Reuse only committed pages and the original resolved latest target.
                release.set()
                TaskNode.state_page_gate = None
                TaskNode.latest = 201
                before = len(TaskNode.calls)
                retry = cli(url, 'task', 'retry', '--id', task_id)
                resumed = wait_task(url, retry['task_id'])
                assert retry['retry_of'] == task_id and not retry['cancel_requested']
                assert resumed['result'][0]['ledger_index'] == 200
                pages = [p for m, p in TaskNode.calls[before:] if m == 'ledger_data']
                assert [p.get('marker') for p in pages] == ['1', '2', '3']
                assert all(p['ledger_hash'] == Node.hash200 for p in pages)
                assert cli(url, 'jobs', '-b', 'running') == []
                assert cli(url, 'ledgers', '-b', 'running')[0]['trust'] == 'untrusted'
                assert len(history(url, task_id)) == len(journal)
            with backend(data, rpc) as (url, _):
                assert request(url, '/tasks/' + task_id) == cancelled
                assert request(url, '/tasks/' + queued_id) == cancelled_queue
                assert len(history(url, task_id)) == len(journal)

            # Upgrade a populated legacy task table with self and event references.
            legacy = Path(tmp) / 'legacy'
            with backend(legacy, rpc) as (url, _):
                failed = request(url, '/tasks', {'kind': 'fetch', 'request': {'from': 0}}, 202)
                failed = wait_task(url, failed['task_id'], 'failed')
                retried = cli(url, 'task', 'retry', '--id', failed['task_id'])
                retried = wait_task(url, retried['task_id'], 'failed')
                old_history = history(url, failed['task_id'])
            with sqlite3.connect(legacy / 'xl.sqlite3') as db:
                table_sql = db.execute("SELECT sql FROM sqlite_master WHERE name='acquisition_tasks'").fetchone()[0]
                table_sql = table_sql.replace('acquisition_tasks(', 'old_tasks(', 1)
                # SQLite may quote table names after ALTER TABLE.
                table_sql = table_sql.replace('"acquisition_tasks"(', 'old_tasks(', 1)
                table_sql = table_sql.replace(",'cancelled'", '').split(',\n    cancel_requested')[0] + ')'
                columns = [r[1] for r in db.execute('PRAGMA table_info(acquisition_tasks)') if r[1] != 'cancel_requested']
                names = ','.join(columns)
                db.executescript(f"PRAGMA foreign_keys=OFF; PRAGMA legacy_alter_table=ON; BEGIN; {table_sql}; "
                                 f"INSERT INTO old_tasks SELECT {names} FROM acquisition_tasks; DROP TABLE acquisition_tasks; "
                                 "ALTER TABLE old_tasks RENAME TO acquisition_tasks; COMMIT;")
            with backend(legacy, rpc) as (url, _):
                assert request(url, '/tasks/' + failed['task_id']) == failed
                assert request(url, '/tasks/' + retried['task_id']) == retried
                assert history(url, failed['task_id']) == old_history
                with sqlite3.connect(legacy / 'xl.sqlite3') as db:
                    assert db.execute('PRAGMA foreign_key_check').fetchall() == []
                    assert db.execute("SELECT count(*) FROM sqlite_master WHERE name='acquisition_tasks_active'").fetchone()[0] == 1
            # Simulate a crash after a durable cancellation request but before unwind.
            with sqlite3.connect(data / 'xl.sqlite3') as db:
                db.execute("UPDATE acquisition_tasks SET status='running',finished_at=NULL WHERE id=?", (task_id,))
                db.commit()
            with backend(data, rpc) as (url, _):
                assert request(url, '/tasks/' + task_id)['status'] == 'cancelled'
    finally:
        if release:
            release.set()
        TaskNode.state_page_gate = None
        server.shutdown()
        server.server_close()
        thread.join()

    server = ThreadingHTTPServer(('127.0.0.1', 0), RetryNode)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='xl-cancel-backoff-') as tmp:
            RetryNode.failures = 100
            RetryNode.failure_mode = '503'
            with backend(Path(tmp) / 'data', f'http://127.0.0.1:{server.server_port}') as (url, _):
                retrying = cli(url, 'bundle', 'new', '-b', 'backoff', '-i', 200, '--detach')
                wait_progress(url, retrying['task_id'], lambda t: (t['progress'] or {}).get('retry_attempt', 0) >= 2)
                started = time.monotonic()
                cli(url, 'task', 'cancel', '--id', retrying['task_id'])
                wait_task(url, retrying['task_id'], 'cancelled')
                assert time.monotonic() - started < 2
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    print('PASS running/queued cancellation, blocked RPC and retry backoff, scoping, observers, idempotence, queue continuity, checkpoint retry, restart and legacy migration')


if __name__ == '__main__':
    main()
