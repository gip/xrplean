"""Cancel queued/running verification without losing artifacts or granting proof receipts."""
from pathlib import Path
import json
import os
import shutil
import signal
import sqlite3
import sys
import tempfile
import time

from integration import EXPORT, TREE, anchor, backend, cli, request, wait_job


def wait_file(path):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(.02)
    raise AssertionError(f'proof process did not reach {path}')


def main():
    with tempfile.TemporaryDirectory(prefix='xl-job-cancel-') as tmp:
        folder = Path(tmp)
        bins = folder / 'bin'
        bins.mkdir()
        gate = folder / 'started'
        release = folder / 'release'
        for name, real in [('python3', sys.executable), ('lake', shutil.which('lake'))]:
            script = bins / name
            script.write_text(f'''#!{sys.executable}
import os, pathlib, subprocess, sys, time
if any('generate_merkle_certificate.py' in a or 'Payments.lean' in a for a in sys.argv[1:]):
    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(300)'])
    pathlib.Path({str(gate)!r}).write_text(str(child.pid))
    while not pathlib.Path({str(release)!r}).exists(): time.sleep(.02)
os.execv({real!r}, [{real!r}] + sys.argv[1:])
''')
            script.chmod(0o755)
        env = {'PATH': str(bins) + os.pathsep + os.environ['PATH']}
        for kind in ['merkle', 'payments']:
            gate.unlink(missing_ok=True)
            data = folder / kind
            with backend(data, env=env) as (url, _):
                request(url, '/ledgers', EXPORT, 204)
                if kind == 'merkle':
                    request(url, '/ledgers', anchor(), 204)
                    request(url, '/trust', {'ledger_index': 99, 'ledger_hash': EXPORT['parent_ledger_hash'], 'reason': 'test'})
                    request(url, '/state', {'ledger_index': 99, 'ledger_hash': EXPORT['parent_ledger_hash'], 'nodes': TREE['nodes']}, 201)
                task_id = request(url, '/jobs', {'from': 100, 'to': 101, 'checks': [kind]}, 202)['job_id']
                wait_file(gate)
                descendant = int(gate.read_text())
                original = request(url, '/jobs/' + task_id)
                assert original['status'] == 'running' and original['verifications'][0]['attempt_dir']
                attempt = Path(original['verifications'][0]['attempt_dir'])
                retained = (attempt / 'export.json').read_bytes()
                queued = request(url, '/jobs', {'from': 102, 'checks': ['merkle']}, 202)['job_id']
                assert request(url, '/jobs/' + queued)['status'] == 'queued'
                assert 'job not found' in request(url, '/bundles/other/jobs/' + task_id + '/cancel', {}, 422)['error']
                assert not request(url, '/jobs/' + task_id)['cancel_requested']
                cancelled_queue = cli(url, 'job', 'cancel', '--id', queued)
                assert cancelled_queue['status'] == 'cancelled' and cancelled_queue['cancel_requested']
                assert all(i['status'] == 'cancelled' for i in cancelled_queue['items'])
                assert cancelled_queue['verifications'] == []
                assert cli(url, 'job', 'cancel', queued) == cancelled_queue
                following = request(url, '/jobs', {'from': 103, 'checks': ['merkle']}, 202)['job_id']
                started = time.monotonic()
                accepted = cli(url, 'job', 'cancel', '--id', task_id)
                assert accepted['cancel_requested']
                cancelled = wait_job(url, task_id, 'cancelled', timeout=5)
                assert time.monotonic() - started < 3
                assert all(i['status'] == 'cancelled' for i in cancelled['items'])
                assert all(v['status'] == 'cancelled' for v in cancelled['verifications'])
                assert cancelled['verifications'][0]['attempt_dir'] == str(attempt)
                assert (attempt / 'export.json').read_bytes() == retained
                assert cancelled['verifications'][0]['artifacts_json'] == '[]'
                assert cli(url, 'job', 'cancel', '--id', task_id) == cancelled
                assert next(j for j in cli(url, 'job', 'show') if j['job_id'] == queued)['status'] == 'cancelled'
                blocked = wait_job(url, following, 'blocked')
                assert cli(url, 'job', 'cancel', '--id', following) == blocked
                assert request(url, '/health')['service'] == 'XLB'
                # A cancelled process group must not leave child compilers running.
                try:
                    os.kill(descendant, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError(f'proof descendant still running: {descendant}')
                with sqlite3.connect(data / 'xl.sqlite3') as db:
                    assert db.execute("SELECT count(*) FROM verifications WHERE job_id=? AND status='kernel_checked'", (task_id,)).fetchone()[0] == 0
                    assert db.execute('PRAGMA foreign_key_check').fetchall() == []
            with backend(data) as (url, _):
                assert request(url, '/jobs/' + task_id) == cancelled
                assert request(url, '/jobs/' + queued) == cancelled_queue

        # Upgrade an existing populated jobs table, retaining items and attempts.
        data = folder / 'payments'
        with sqlite3.connect(data / 'xl.sqlite3') as db:
            # Cancellation rows are unavailable in the old schema; keep their IDs/history as interrupted.
            db.execute("UPDATE jobs SET status='interrupted' WHERE status='cancelled'")
            db.commit()
            columns = [r[1] for r in db.execute('PRAGMA table_info(jobs)') if r[1] != 'cancel_requested']
            names = ','.join(columns)
            db.executescript(f'''PRAGMA foreign_keys=OFF; PRAGMA legacy_alter_table=ON; BEGIN;
                CREATE TABLE jobs_old(id INTEGER PRIMARY KEY,network INTEGER NOT NULL,first_idx INTEGER NOT NULL,
                  last_idx INTEGER NOT NULL,checks_json TEXT NOT NULL,status TEXT NOT NULL CHECK(status IN
                  ('queued','running','succeeded','blocked','failed','unsupported','interrupted')),
                  error TEXT NOT NULL DEFAULT '',created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,bundle TEXT NOT NULL DEFAULT 'default');
                INSERT INTO jobs_old({names}) SELECT {names} FROM jobs;
                DROP TABLE jobs; ALTER TABLE jobs_old RENAME TO jobs; COMMIT;''')
        with backend(data) as (url, _):
            saved = request(url, '/jobs/' + task_id)
            assert saved['status'] == 'interrupted' and not saved['cancel_requested']
            assert saved['verifications'] == cancelled['verifications']
            with sqlite3.connect(data / 'xl.sqlite3') as db:
                assert db.execute('PRAGMA foreign_key_check').fetchall() == []
                # Simulate a hard crash between receipt and cancellation cleanup.
                db.execute("UPDATE jobs SET status='running',cancel_requested=1 WHERE id=?", (task_id,))
                db.execute("UPDATE job_items SET status='running' WHERE job_id=?", (task_id,))
                db.execute("UPDATE verifications SET status='running' WHERE job_id=?", (task_id,))
                db.commit()
        with backend(data) as (url, _):
            assert request(url, '/jobs/' + task_id)['status'] == 'cancelled'
    print('PASS Merkle/Payment and queued cancellation, proof process groups, preserved artifacts, no false receipts, scoping, idempotence, queue continuity, restart and legacy migration')


if __name__ == '__main__':
    main()
