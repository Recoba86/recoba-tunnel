#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> bash syntax"
bash -n install.sh

echo "==> pure logic tests"
bash scripts/test_pure_logic.sh

echo "==> golden config tests"
bash scripts/test_golden_configs.sh

echo "==> dry-run tests"
bash scripts/test_dry_run.sh

echo "==> menu smoke tests"
bash scripts/test_menu_smoke.sh

echo "==> ShellCheck"
if command -v shellcheck >/dev/null 2>&1; then
    if [ "${PAQET_SHELLCHECK_STRICT:-0}" = "1" ]; then
        shellcheck install.sh scripts/*.sh
    else
        if shellcheck install.sh scripts/*.sh; then
            echo "ShellCheck passed."
        else
            echo "ShellCheck reported issues. Continuing because PAQET_SHELLCHECK_STRICT is not set to 1." >&2
        fi
    fi
else
    echo "ShellCheck not installed; skipping. Set PAQET_SHELLCHECK_STRICT=1 only on systems with ShellCheck installed." >&2
fi

echo "Validation completed."
