"""Crash recovery uses committed NuDB pages, including a crash between flush and COMMIT."""
from http.server import ThreadingHTTPServer
from pathlib import Path
import json
import signal
import sqlite3
import tempfile
import threading
from acquisition import Node, ENTRIES, STATE_ROOT
from integration import backend, cli, request
from progress import stream


class ResumeNode(Node):
    calls = []


def checkpoint(data):
    with sqlite3.connect(data / 'xl.sqlite3') as db:
        path, status, scope = db.execute('SELECT path,status,scope FROM state_downloads').fetchone()
        assert db.execute('SELECT count(*) FROM trust_anchors').fetchone()[0] == 0
    with sqlite3.connect(path) as catalog:
        text = catalog.execute("SELECT value FROM metadata WHERE key=?", (f"acquisition/{scope}/xl_download" if scope else "xl_download",)).fetchone()[0]
        assert catalog.execute('SELECT backend FROM node_storage').fetchone()[0] == 'nudb-v1'
    return path, status, json.loads(text)


def main():
    paused, release = threading.Event(), threading.Event()

    def gate(page):
        if page == 1:
            paused.set()
            assert release.wait(15)

    ResumeNode.state_page_gate = gate
    server = ThreadingHTTPServer(('127.0.0.1', 0), ResumeNode)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    rpc = f'http://127.0.0.1:{server.server_port}'
    try:
        with tempfile.TemporaryDirectory(prefix='xl-resume-') as tmp:
            data = Path(tmp) / 'data'
            with backend(data, rpc, expected_exit=-signal.SIGKILL) as (url, process):
                with stream(url, {'from': 200, 'state': True}) as response:
                    events = []
                    while True:
                        event = json.loads(response.readline())
                        events.append(event)
                        if event.get('pages') == 1:
                            break
                    assert paused.wait(5)
                    path, status, saved = checkpoint(data)
                    assert saved['progress']['entries'] == saved['progress']['pages'] == 1
                    assert saved['marker'] == '1' and not saved['done']
                    assert status == 'downloading'
                    assert request(url, '/ledgers')[0]['state'] == 'missing'
                    # A simultaneous writer must not replace the active catalog.
                    assert 'already in use' in cli(url, 'fetch', 200, '--state', success=False)
                    assert checkpoint(data)[0] == path
                    process.kill()
                    process.wait(5)
                release.set()
            ResumeNode.state_page_gate = None
            # Crash after the second page's payload flush, before the cursor and
            # catalog COMMIT. Recovery must still point to the first page.
            before = len(ResumeNode.calls)
            with backend(data, rpc, expected_exit=86,
                         env={'LEANXRPL_STORAGE_TEST_FAULT': 'after-node-flush'}) as (url, process):
                with stream(url, {'from': 200, 'state': True}) as response:
                    interrupted = [json.loads(line) for line in response if line.strip()]
                process.wait(10)
                assert not any(e.get('phase') == 'complete' for e in interrupted)
                first = interrupted[0]
                assert first['phase'] == 'resuming' and first['pages'] == 1
                assert first['entries'] == 1 and first['keyspace_permille'] > 0
            assert checkpoint(data)[2] == saved
            data_calls = [p for m, p in ResumeNode.calls[before:] if m == 'ledger_data']
            assert [p.get('marker') for p in data_calls] == ['1']
            # Resume again without fault injection: first progress retains counters,
            # the header is selected by hash, and page zero is never requested.
            before = len(ResumeNode.calls)
            with backend(data, rpc) as (url, _):
                with stream(url, {'from': 200, 'state': True}) as response:
                    resumed = [json.loads(line) for line in response if line.strip()]
                assert resumed[-1]['event'] == 'result', resumed
                assert resumed[0]['phase'] == 'resuming'
                for field in ('entries', 'pages', 'state_bytes', 'keyspace_permille', 'elapsed_ms'):
                    assert resumed[0][field] == saved['progress'][field]
                assert all(e.get('entries', 1) >= 1 for e in resumed)
                calls = ResumeNode.calls[before:]
                assert [p.get('marker') for m, p in calls if m == 'ledger_data'] == ['1', '2', '3']
                assert next(p for m, p in calls if m == 'ledger')['ledger_hash'] == Node.hash200
                final_path, status, finished = checkpoint(data)
                assert final_path == path and status == 'complete' and finished['done']
                assert finished['root'] == STATE_ROOT
                assert finished['progress']['entries'] == len(ENTRIES)
                assert [p.resolve() for p in data.glob('*.sqlite3.nodes')] == [Path(path + '.nodes').resolve()]
                # A completed snapshot is reused, rather than fetched again.
                before = len(ResumeNode.calls)
                cli(url, 'fetch', 200, '--state')
                assert not any(m == 'ledger_data' for m, _ in ResumeNode.calls[before:])
                assert checkpoint(data)[0] == path
                assert request(url, '/ledgers')[0]['trust'] == 'untrusted'
        print('PASS hard restart, atomic flush/commit recovery, restored nonzero progress, pinned hash, writer exclusion, complete reuse, and NuDB')
    finally:
        release.set()
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    main()
