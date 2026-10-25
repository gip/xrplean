"""Full browser/proxy/Lean test. Requires frontend pnpm dependencies and Playwright Chromium."""
from http.server import ThreadingHTTPServer
from pathlib import Path
import os
import subprocess
import tempfile
import threading
import time
from integration import ROOT, backend, cli, free_port, request
from acquisition import Node, ENTRIES, STATE_ROOT
import json


class BrowserNode(Node):
    def do_POST(self):
        # Both synthetic ledgers have the same authenticated complete state.
        if self.path != "/":
            return super().do_POST()
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        posted = json.loads(raw)
        if posted["method"] != "ledger_data":
            import io
            self.rfile = io.BytesIO(raw)
            return super().do_POST()
        ledger_hash = posted["params"][0]["ledger_hash"]
        index = 200 if ledger_hash == self.hash200 else 201
        body = json.dumps({"result": {"status": "success", "ledger_index": index,
            "ledger_hash": ledger_hash, "state": ENTRIES}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    rpc = ThreadingHTTPServer(('127.0.0.1', 0), BrowserNode)
    threading.Thread(target=rpc.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='xl-frontend-') as tmp:
            folder = Path(tmp)
            with backend(folder / 'data', f'http://127.0.0.1:{rpc.server_port}') as (url, _):
                cli(url, 'ledger', 'get', '--index', '200', '--state', '--transport', 'rpc')
                cli(url, 'ledger', 'get', '--index', '201', '--state', '--transport', 'rpc')
                request(url, '/ledgers', dict(schema_version=1, stage='accepted', network_id=0,
                    ledger_index=201, ledger_hash=Node.hash201, parent_ledger_hash=Node.hash200,
                    parent_state_root=STATE_ROOT, state_root=STATE_ROOT,
                    pre_transaction_changes=[], transactions=[], post_transaction_changes=[]), 204)
                port = free_port()
                with open(folder / 'ui.log', 'w+') as log:
                    ui = subprocess.Popen(['node', str(ROOT / 'frontend/server.ts'), '--dev', '--port', str(port), '--backend', url], cwd=ROOT, stdout=log, stderr=log)
                    try:
                        origin = f'http://127.0.0.1:{port}'
                        for _ in range(100):
                            if ui.poll() is not None:
                                log.seek(0)
                                raise AssertionError(log.read())
                            try:
                                request(origin, '/api/health')
                                break
                            except OSError:
                                time.sleep(.1)
                        else:
                            raise AssertionError('UI did not start')
                        result = subprocess.run(['node', str(ROOT / 'frontend/tests/real-backend.ts'), origin], cwd=ROOT, env=os.environ.copy(), capture_output=True, text=True, timeout=240)
                        assert result.returncode == 0, result.stdout + result.stderr
                        print(result.stdout.strip())
                    finally:
                        ui.terminate()
                        ui.wait(timeout=15)
    finally:
        rpc.shutdown()
        rpc.server_close()


if __name__ == '__main__':
    main()
