"""Process lifecycle for ./xl; ledger operations remain in the Lean applications."""
from pathlib import Path
import argparse
import fcntl
import hashlib
import json
import os
import signal
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / '.lake/build/bin/xlb'


def identity(pid):
    """Bind the PID to its start time and command to avoid signalling a reused PID."""
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=', '-o', 'command='],
                            capture_output=True, text=True, env={**os.environ, 'TZ': 'UTC', 'LC_ALL': 'C'})
    if result.returncode:
        return None
    text = result.stdout.strip()
    return hashlib.sha256(text.encode()).hexdigest() if text else None


def record(data):
    file = data / 'backend-process.json'
    if not file.exists():
        return None
    return json.loads(file.read_text())


def running(saved):
    if not saved:
        return False
    return identity(saved['pid']) == saved['identity']


def executable():
    digest = hashlib.sha256()
    with BIN.open('rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            digest.update(block)
    return dict(path=str(BIN.resolve()), sha256=digest.hexdigest())


def write_json(path, value):
    staging = path.parent / f'.{path.name}-{os.getpid()}-{time.monotonic_ns()}'
    try:
        descriptor = os.open(staging, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as file:
            file.write(json.dumps(value) + '\n')
            file.flush()
            os.fsync(file.fileno())
        staging.replace(path)
    finally:
        staging.unlink(missing_ok=True)


def configuration(args):
    return dict(listen=args.listen, rpc=args.rpc, network_id=args.network_id,
                project_root=args.project_root, peer=getattr(args, 'peer', None),
                peer_timeout=getattr(args, 'peer_timeout', 30),
                proof_jobs=getattr(args, 'proof_jobs', 6),
                rpc_backoff_max=getattr(args, 'rpc_backoff_max', 30),
                batch_service_address=getattr(args, 'batch_service_address', ''),
                batch_service_fee=getattr(args, 'batch_service_fee', 0))


def stop(data):
    saved = record(data)
    if not running(saved):
        (data / 'backend-process.json').unlink(missing_ok=True)
        print('XLB is stopped (no managed backend).')
        return True
    os.kill(saved['pid'], signal.SIGTERM)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if not running(saved):
            (data / 'backend-process.json').unlink(missing_ok=True)
            print('XLB stopped.')
            return True
        time.sleep(.1)
    print(f"XLB is still stopping (PID {saved['pid']}); see {data / 'backend.log'}", file=sys.stderr)
    return False


def start(args, data):
    saved = record(data)
    desired = executable()
    config = configuration(args)
    if running(saved):
        if saved.get('executable') == desired and saved.get('config') == config:
            print(f"XLB already current at {saved['url']} (PID {saved['pid']}).")
            return True
        print('Updating XLB to the current executable and configuration.')
        if not stop(data):
            return False
    url = 'http://' + args.listen
    command = [str(BIN), '--data', str(data), '--listen', args.listen, '--rpc', args.rpc,
               '--network-id', str(args.network_id), '--project-root', args.project_root]
    if config['peer']:
        command += ['--peer', config['peer']]
    command += ['--peer-timeout', str(config['peer_timeout'])]
    command += ['--rpc-backoff-max', str(config['rpc_backoff_max'])]
    command += ['--proof-jobs', str(config['proof_jobs'])]
    if config['batch_service_address']:
        command += ['--batch-service-address', config['batch_service_address'],
                    '--batch-service-fee', str(config['batch_service_fee'])]
    logfile = data / 'backend.log'
    with logfile.open('ab', buffering=0) as log:
        child = subprocess.Popen(command, cwd=ROOT, stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=log, start_new_session=True)
    try:
        for _ in range(100):
            if child.poll() is not None:
                raise RuntimeError(f'XLB exited ({child.returncode}); see {logfile}')
            try:
                with urllib.request.urlopen(url + '/health', timeout=.5) as response:
                    health = json.load(response)
                if health.get('pid') == child.pid:
                    break
            except OSError:
                pass
            time.sleep(.1)
        else:
            raise RuntimeError(f'XLB did not become ready; see {logfile}')
        # Bind identity once startup has settled. Interpreters/wrappers may
        # update their process command while initializing. Popen still owns
        # this child, and an exited unreaped child cannot have its PID reused.
        owner = identity(child.pid)
        if not owner or child.poll() is not None:
            raise RuntimeError('could not establish backend process identity')
        if executable() != desired:
            raise RuntimeError('XLB executable changed during startup; run ./xl start again')
        state = dict(pid=child.pid, identity=owner, url=url, config=config, executable=desired)
        write_json(data / 'backend-config.json', config)
        write_json(data / 'backend-process.json', state)
        print(f'XLB running at {url} (PID {child.pid}). Log: {logfile}')
        return True
    except BaseException:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                print(f'XLB is still stopping (PID {child.pid}).', file=sys.stderr)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['start', 'stop', 'status', 'restart'],
                        help='start ensures XLB is current; restart is an alias for start')
    parser.add_argument('--data', default='.xl', help='backend data directory')
    parser.add_argument('--listen')
    parser.add_argument('--rpc')
    # Accept old scripts without retaining their obsolete finite retry budget.
    parser.add_argument('--rpc-retries', type=int, help=argparse.SUPPRESS)
    parser.add_argument('--rpc-backoff-max', type=int, help='maximum RPC retry delay in seconds (default 30)')
    parser.add_argument('--peer', help='one xrpld peer endpoint; no discovery or redirect following')
    parser.add_argument('--peer-timeout', type=int, help='seconds without useful state progress before RPC fallback')
    parser.add_argument('--proof-jobs', type=int, help='parallel Merkle hash proof workers, 1..64 (default 6)')
    parser.add_argument('--batch-service-address', help='classic XRPL service-fee recipient')
    parser.add_argument('--batch-service-fee', type=int, help='exact service fee per Batch, in drops')
    parser.add_argument('--network-id', type=int)
    parser.add_argument('--project-root')
    args = parser.parse_args()
    data = Path(args.data).expanduser().resolve()
    if args.action in ('stop', 'status') and not data.exists():
        print('XLB is stopped (no managed backend).')
        return 0 if args.action == 'stop' else 1
    data.mkdir(parents=True, exist_ok=True)
    with (data / 'launcher.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        saved = record(data)
        previous = {}
        if args.action in ('start', 'restart'):
            config_file = data / 'backend-config.json'
            previous = saved.get('config', {}) if saved else (
                json.loads(config_file.read_text()) if config_file.exists() else {})
        defaults = dict(listen='127.0.0.1:4001', rpc='http://127.0.0.1:5005',
                        network_id=0, project_root=str(ROOT), peer=None, peer_timeout=30,
                        rpc_backoff_max=30, proof_jobs=6, batch_service_address='', batch_service_fee=0)
        for key, default in defaults.items():
            if getattr(args, key) is None:
                value = previous.get(key, default)
                if key == 'rpc_backoff_max':
                    value = min(30, value)
                setattr(args, key, value)
        if args.action in ('start', 'restart'):
            if not 0 <= args.network_id <= 4294967295:
                raise ValueError('network ID out of range')
            if not 1 <= args.rpc_backoff_max <= 30:
                raise ValueError('RPC backoff cap must be 1..30 seconds')
            if not 1 <= args.proof_jobs <= 64:
                raise ValueError('proof worker count must be 1..64')
            if bool(args.batch_service_address) != bool(args.batch_service_fee):
                raise ValueError('configure both --batch-service-address and --batch-service-fee')
            if not 0 <= args.batch_service_fee <= 100000000000000000:
                raise ValueError('invalid batch service fee in drops')
            args.project_root = str(Path(args.project_root).expanduser().resolve())
        if args.action == 'status':
            saved = record(data)
            if running(saved):
                print(f"XLB running at {saved['url']} (PID {saved['pid']}).")
                return 0
            print('XLB is stopped (no managed backend).')
            return 1
        if args.action == 'stop' and not stop(data):
            return 1
        if args.action in ('start', 'restart'):
            return 0 if start(args, data) else 1
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
