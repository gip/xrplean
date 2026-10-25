"""Single-entry-point CLI and managed backend lifecycle; all data stays temporary."""
from pathlib import Path
from argparse import Namespace
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from integration import ROOT, free_port, request

XL = ROOT / 'xl'


def run(*args, code=0, cwd=ROOT):
    p = subprocess.run([str(XL), *map(str, args)], cwd=cwd, capture_output=True, text=True, timeout=60)
    assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
    return p


def main():
    with tempfile.TemporaryDirectory(prefix='xl-launcher-') as tmp:
        data = Path(tmp) / 'data'
        port = free_port()
        url = f'http://127.0.0.1:{port}'
        flags = ['--data', data, '--listen', f'127.0.0.1:{port}',
                 '--peer', '127.0.0.1:2459', '--peer-timeout', '7',
                 '--rpc-retries', '3', '--rpc-backoff-max', '2', '--proof-jobs', '3']
        try:
            help_text = run('--help', cwd=tmp).stdout
            assert './xl start' in help_text
            assert './xl ledger get --bundle NAME --index' in help_text
            assert './xl job show' in help_text
            assert 'ledger get' in run('ledger', '--help', cwd=tmp).stdout
            run('status', '--data', data, code=1)
            assert not data.exists()
            run('start', *flags)
            first = json.loads((data / 'backend-process.json').read_text())
            assert first['config']['peer'] == '127.0.0.1:2459' and first['config']['peer_timeout'] == 7
            assert 'rpc_retries' not in first['config'] and first['config']['rpc_backoff_max'] == 2
            assert first['config']['proof_jobs'] == 3
            for invalid in ('0', '65', 'invalid'):
                run('start', *flags, '--proof-jobs', invalid, code=2 if invalid == 'invalid' else 1)
                run('serve', '--data', data, '--proof-jobs', invalid, code=1)
            assert json.loads((data / 'backend-process.json').read_text())['pid'] == first['pid']
            assert 'XLB running' in run('status', '--data', data).stdout
            assert json.loads(run('--backend', url, 'health').stdout)['state_backend'] == 'nudb'
            assert json.loads(run('ledger', 'show', '--backend', url).stdout) == []
            assert json.loads(run('job', 'show', '--backend', url).stdout) == []
            assert json.loads(run('task', 'show', '--backend', url).stdout) == []
            assert json.loads(run('bundle', 'show', '--backend', url).stdout)[0]['bundle'] == 'default'
            run('start', *flags)
            assert json.loads((data / 'backend-process.json').read_text())['pid'] == first['pid']
            run('start', '--data', data)
            assert json.loads((data / 'backend-process.json').read_text()) == first
            run('restart', '--data', data)
            assert json.loads((data / 'backend-process.json').read_text()) == first
            # Changed settings take effect through start; omitted options persist.
            run('start', '--data', data, '--network-id', 1)
            second = json.loads((data / 'backend-process.json').read_text())
            assert second['pid'] != first['pid']
            assert second['url'] == first['url']
            assert json.loads(run('--backend', url, 'health').stdout)['network_id'] == 1
            # Upgrade saved finite budgets/caps without retaining a retry limit.
            old_config = dict(second['config'], rpc_retries=8, rpc_backoff_max=120)
            del old_config['proof_jobs']
            (data / 'backend-process.json').write_text(json.dumps(dict(second, config=old_config)))
            run('start', '--data', data)
            migrated = json.loads((data / 'backend-process.json').read_text())
            assert migrated['pid'] != second['pid']
            assert 'rpc_retries' not in migrated['config'] and migrated['config']['rpc_backoff_max'] == 30
            assert migrated['config']['proof_jobs'] == 6
            second = migrated
            # Older launch records without a binary fingerprint upgrade once.
            legacy = dict(second)
            del legacy['executable']
            (data / 'backend-process.json').write_text(json.dumps(legacy))
            run('start', '--data', data)
            third = json.loads((data / 'backend-process.json').read_text())
            assert third['pid'] != second['pid'] and third['config'] == second['config']
            run('start', '--data', data)
            assert json.loads((data / 'backend-process.json').read_text()) == third
            run('stop', '--data', data)
            run('status', '--data', data, code=1)
            run('start', '--data', data)
            assert json.loads((data / 'backend-process.json').read_text())['config'] == third['config']
            assert json.loads(run('--backend', url, 'health').stdout)['network_id'] == 1
            run('stop', '--data', data)
            # New Batch settings are optional, saved together, and can be disabled.
            service = 'rPT1Sjq2YGrBMTttX4GZHjKu9dyfzbpAYe'
            run('start', '--data', data, '--batch-service-address', service, code=1)
            run('start', '--data', data, '--batch-service-address', service, '--batch-service-fee', '1000')
            configured = json.loads((data / 'backend-process.json').read_text())
            assert configured['config']['batch_service_address'] == service
            assert configured['config']['batch_service_fee'] == 1000
            assert request(url, '/batches/policy')['enabled']
            run('start', '--data', data)
            assert json.loads((data / 'backend-process.json').read_text())['pid'] == configured['pid']
            run('stop', '--data', data)
            run('start', '--data', data)
            assert request(url, '/batches/policy')['policy']['service_address'] == service
            run('start', '--data', data, '--batch-service-address', '', '--batch-service-fee', '0')
            assert not request(url, '/batches/policy')['enabled']
            run('stop', '--data', data)
            # A stale ownership record must not cause a signal to an unrelated process.
            (data / 'backend-process.json').write_text(json.dumps(dict(pid=os.getpid(), identity='stale', url=url)))
            run('stop', '--data', data)
            assert not (data / 'backend-process.json').exists()
        finally:
            run('stop', '--data', data)
    binary_upgrade()
    print('PASS ./xl, current-process reuse, executable/config upgrades, restart alias, saved settings, stop, and stale PID protection')


def binary_upgrade():
    """Change a real running test executable without mutating the Lean binary."""
    spec = importlib.util.spec_from_file_location('xl_lifecycle', ROOT / 'tools/backend.py')
    lifecycle = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lifecycle)
    with tempfile.TemporaryDirectory(prefix='xl-binary-upgrade-') as tmp:
        folder = Path(tmp)
        lifecycle.BIN = folder / 'backend'
        data = folder / 'data'
        data.mkdir()
        args = Namespace(listen=f'127.0.0.1:{free_port()}', rpc='http://127.0.0.1:5005',
                         network_id=0, project_root=str(ROOT))
        template = '#!' + sys.executable + '\n' + '''
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
listen = sys.argv[sys.argv.index('--listen') + 1].split(':')
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps(dict(pid=os.getpid(), version=VERSION)).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
HTTPServer((listen[0], int(listen[1])), Handler).serve_forever()
'''
        def install(version):
            lifecycle.BIN.write_text(template.replace('VERSION', str(version)))
            lifecycle.BIN.chmod(0o700)
        try:
            install(1)
            assert lifecycle.start(args, data)
            first = lifecycle.record(data)
            assert lifecycle.start(args, data)
            assert lifecycle.record(data)['pid'] == first['pid']
            install(2)
            assert lifecycle.start(args, data)
            second = lifecycle.record(data)
            assert second['pid'] != first['pid']
            assert second['executable']['sha256'] != first['executable']['sha256']
            from integration import request
            assert request(second['url'], '/health')['version'] == 2
            assert lifecycle.start(args, data)
            assert lifecycle.record(data) == second
        finally:
            assert lifecycle.stop(data)


if __name__ == '__main__':
    main()
