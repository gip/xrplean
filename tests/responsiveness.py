"""Metadata-only inventory reads and liveness under observer saturation.

All large payloads and queue fixtures are synthetic, in temporary databases.
"""
from concurrent.futures import ThreadPoolExecutor
from http.server import ThreadingHTTPServer
from pathlib import Path
import hashlib
import json
import sqlite3
import tempfile
import threading
import time

from integration import EXPORT, backend, request
from tasks import TaskNode, events, pause_page, wait_task


def main():
    node = ThreadingHTTPServer(('127.0.0.1', 0), TaskNode)
    threading.Thread(target=node.serve_forever, daemon=True).start()
    release = threading.Event()
    observers = []
    try:
        with tempfile.TemporaryDirectory(prefix='xl-responsive-') as tmp:
            data = Path(tmp) / 'data'
            with backend(data, f'http://127.0.0.1:{node.server_port}') as (url, _):
                request(url, '/ledgers', EXPORT, 204)
                # received_at follows payload in the table. Without a covering
                # metadata index every poll walks the large overflow chains.
                with sqlite3.connect(data / 'xl.sqlite3') as db:
                    ledger_id = db.execute('SELECT id FROM ledgers').fetchone()[0]
                    for i in range(16):
                        payload = json.dumps({**EXPORT, 'padding': str(i) + 'x' * (8 * 1024 * 1024)})
                        digest = hashlib.sha256(payload.encode()).hexdigest().upper()
                        db.execute('INSERT INTO exports(ledger_id,digest,payload) VALUES(?,?,?)',
                                   (ledger_id, digest, payload))
                    db.commit()
                start = time.monotonic()
                with ThreadPoolExecutor(max_workers=8) as pool:
                    inventories = list(pool.map(lambda _: request(url, '/exports'), range(8)))
                elapsed = time.monotonic() - start
                assert elapsed < 3, f'metadata polling took {elapsed:.2f}s for 128 MiB of payloads'
                assert all(rows == inventories[0] for rows in inventories)
                assert len(inventories[0]) == 17
                assert all(row['received_at'] and row['merkle'] == 'not_checked' for row in inventories[0])
                assert len(json.dumps(inventories[0])) < 20000
                assert request(url, '/ledgers')[0]['export_variants'] == '17'

                paused, release = pause_page()
                task = request(url, '/tasks', {'kind': 'state_new', 'request': {'index': '200'}}, 202)
                task_id = task['task_id']
                assert paused.wait(10)
                try:
                    # Each opened stream occupies one application slot. A ninth
                    # operation must fail promptly, while /health stays usable.
                    for _ in range(8):
                        observer = events(url, task_id)
                        observers.append(observer)
                        assert json.loads(observer.readline())['event'] == 'progress'
                    start = time.monotonic()
                    assert request(url, '/health')['service'] == 'XLB'
                    assert time.monotonic() - start < 1
                    refused = request(url, '/tasks', {'kind': 'fetch', 'request': {'from': 201}}, 503)
                    assert 'not submitted' in refused['error']
                    with sqlite3.connect(data / 'xl.sqlite3') as db:
                        assert db.execute('SELECT count(*) FROM acquisition_tasks').fetchone()[0] == 1
                finally:
                    release.set()
                    for observer in observers:
                        for line in observer:
                            if json.loads(line)['event'] in ('result', 'error'):
                                break
                        observer.close()
                    observers.clear()
                wait_task(url, task_id)
                assert len(request(url, '/tasks')) == 1
                assert len(request(url, '/exports')) >= 17
    finally:
        release.set()
        for observer in observers:
            observer.close()
        TaskNode.state_page_gate = None
        node.shutdown()
        node.server_close()
    print('PASS responsive inventory with 128 MiB payloads, independent health, bounded admission and no duplicate task')


if __name__ == '__main__':
    main()
