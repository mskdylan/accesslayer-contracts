#!/usr/bin/env bash
#
# Run all verification-tooling checks. Used locally and by CI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

SHELL_SCRIPTS=(
  docker/build-wasm.sh
  scripts/build-wasm.sh
  scripts/verify-deployment.sh
  scripts/repro-check.sh
  scripts/tests/verify-deployment-test.sh
  scripts/tests/release-metadata-test.sh
  scripts/tests/run-tests.sh
)

echo "==> Shell syntax checks"
for script in "${SHELL_SCRIPTS[@]}"; do
  bash -n "$script"
  echo "ok: $script"
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "==> ShellCheck"
  shellcheck "${SHELL_SCRIPTS[@]}"
  echo "ok: shellcheck"
else
  echo "==> ShellCheck not installed; skipping"
fi

echo "==> Release metadata validation"
python3 scripts/validate-releases.py

echo "==> Verification script tests"
bash scripts/tests/verify-deployment-test.sh

echo "==> Release metadata tests"
bash scripts/tests/release-metadata-test.sh

echo
echo "All verification tooling checks passed."
