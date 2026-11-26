#!/usr/bin/env bash
#
# Run the validation tests for the reproducibly-build tooling.
#
# These tests are hermetic: they do not need Docker or a Stellar network. The
# deployment verifier is exercised with a prebuilt wasm (--wasm) and a stub
# stellar CLI, so MATCH/MISMATCH/error behaviour and exit codes are covered
# without touching a real network.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

status=0
for test_script in \
  "$SCRIPT_DIR/verify-deployment-test.sh" \
  "$SCRIPT_DIR/release-metadata-test.sh"; do
  if bash "$test_script"; then
    echo "PASS $(basename "$test_script")"
  else
    echo "FAIL $(basename "$test_script")"
    status=1
  fi
done

exit "$status"
