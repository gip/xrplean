.PHONY: build test test-ui

build:
	lake build

test: build
	python3 tests/kernel_checks.py
	python3 tests/witnesses.py
	python3 tests/cli.py
	python3 tests/integration.py
	python3 tests/acquisition.py
	python3 tests/peer_acquisition.py
	python3 tests/incremental.py
	python3 tests/bundle_migration.py
	python3 tests/progress.py
	python3 tests/tasks.py
	python3 tests/cancellation.py
	python3 tests/job_cancellation.py
	python3 tests/rpc_backoff.py
	python3 tests/resume.py
	python3 tests/state_tree.py
	python3 tests/launcher.py
	python3 tests/status.py
	python3 tests/responsiveness.py

test-ui:
	pnpm --dir frontend run build
	pnpm --dir frontend test
	pnpm --dir frontend run test:browser
	python3 tests/frontend.py
