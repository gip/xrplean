#!/usr/bin/env python3
"""Build and run the pinned XRP app in Speculos. Never accesses XLB data or keys."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT / 'tools/speculos-lock.json').read_text())


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(directory):
    directory = directory.resolve()
    source = directory / 'app-xrp'
    manifest = directory / 'build.json'
    elf = source / LOCK['elf_path']
    if manifest.exists():
        saved = json.loads(manifest.read_text())
        if saved.get('pins') != LOCK or not elf.is_file() or digest(elf) != LOCK['elf_sha256']:
            raise RuntimeError('Existing Speculos build does not match its pins. Keep it for inspection and choose a fresh --directory.')
        print(f'Pinned XRP app ready: {elf}', flush=True)
        return elf
    if directory.exists() and any(directory.iterdir()):
        raise RuntimeError('Build directory must be empty or contain a verified build.json; use a fresh --directory after an interrupted build.')
    directory.mkdir(parents=True, exist_ok=True)
    # All downloaded source/build output remains outside the application data directory.
    run('git', 'init', source)
    run('git', '-C', source, 'remote', 'add', 'origin', LOCK['source_url'])
    run('git', '-C', source, 'fetch', '--depth', '1', 'origin', LOCK['source_revision'])
    run('git', '-C', source, 'checkout', '--detach', 'FETCH_HEAD')
    revision = run('git', '-C', source, 'rev-parse', 'HEAD', capture_output=True, text=True).stdout.strip()
    if revision != LOCK['source_revision']:
        raise RuntimeError('XRP source revision mismatch')
    # Docker pulls the digest automatically when it is not cached. Build needs no network.
    run('docker', 'run', '--rm', '--platform', LOCK['platform'], '--network', 'none',
        '-v', f'{source}:/app', '-w', '/app', LOCK['image'], 'sh', '-lc',
        f'test "$(git -C {LOCK["sdk"]} rev-parse HEAD)" = {LOCK["sdk_revision"]} && make -j4 BOLOS_SDK={LOCK["sdk"]}')
    if not elf.is_file() or digest(elf) != LOCK['elf_sha256']:
        raise RuntimeError('Built XRP ELF digest differs from the verified pin; artifacts retained for inspection')
    with manifest.open('x') as output:
        json.dump({'pins': LOCK, 'elf': str(elf)}, output, indent=2)
        output.write('\n')
    print(f'Pinned XRP {LOCK["app_version"]} ready: {elf}', flush=True)
    return elf


def main():
    parser = argparse.ArgumentParser(description='Development-only Speculos XRP app using its built-in public test seed. Never fund its account.')
    parser.add_argument('action', choices=['prepare', 'run'])
    parser.add_argument('--directory', type=Path, default=Path(tempfile.gettempdir()) / 'xrplean-speculos')
    parser.add_argument('--port', type=int, default=5000, help='Loopback emulator web/API port (run only)')
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error('--port must be 1–65535')
    elf = prepare(args.directory)
    if args.action == 'prepare':
        return
    name = f'xrplean-speculos-{args.port}'
    print(f'Speculos XRP test account: {LOCK["test_address"]} (never fund)\nEmulator: http://127.0.0.1:{args.port}\nUI: ./xl ui --dev --speculos http://127.0.0.1:{args.port}', flush=True)
    process = subprocess.Popen(['docker', 'run', '--rm', '--platform', LOCK['platform'],
        '--name', name, '--label', 'org.xrplean.speculos=development',
        '-p', f'127.0.0.1:{args.port}:5000', '-v', f'{elf}:/app/xrp.elf:ro', LOCK['image'],
        'speculos', '--display', 'headless', '--model', LOCK['model'], '--api-port', '5000', '--apdu-port', '0', '/app/xrp.elf'])
    try:
        code = process.wait()
        if code:
            raise RuntimeError(f'Speculos container exited with status {code}')
    except KeyboardInterrupt:
        # Stop only the container created by this foreground command.
        if process.poll() is None:
            subprocess.run(['docker', 'stop', '--time', '3', name], check=False, stdout=subprocess.DEVNULL)
            process.wait(timeout=10)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Speculos: {error}', file=sys.stderr)
        sys.exit(1)
