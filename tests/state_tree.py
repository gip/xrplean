"""Compare batched construction with the imported per-entry reference on NuDB."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    subprocess.run(['lake', 'build', 'state_tree_bench'], cwd=ROOT, check=True)
    with tempfile.TemporaryDirectory(prefix='xl-tree-bench-') as tmp:
        result = subprocess.run([str(ROOT / '.lake/build/bin/state_tree_bench'), tmp],
                                cwd=ROOT, capture_output=True, text=True, timeout=180)
        assert result.returncode == 0, (result.stdout, result.stderr)
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        assert len(rows) == 3, rows
        for row in rows:
            assert row['bulk_writes'] <= row['baseline_writes'], row
            print(json.dumps(row), flush=True)
        # Operation counts are deterministic; elapsed speed is reported, not
        # asserted, because CI hardware and fsync latency differ.
        assert rows[-1]['bulk_writes'] < rows[-1]['baseline_writes'] // 2
    print('PASS reference-equivalent roots, authenticated reopened paths, empty/singleton/deep-prefix cases, rollback, ordering, and fewer NuDB writes')


if __name__ == '__main__':
    main()
