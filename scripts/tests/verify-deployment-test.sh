#!/usr/bin/env bash
#
# Tests for scripts/verify-deployment.sh.
#
# A prebuilt wasm (--wasm) stands in for the container build and a stub stellar
# CLI answers `contract fetch`, so the comparison, reporting and exit-code
# behaviour are covered without Docker or network access.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
. "$REPO_ROOT/scripts/lib/sha256.sh"
VERIFY="$REPO_ROOT/scripts/verify-deployment.sh"

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

CONTRACT_ID="C$(printf 'A%.0s' $(seq 1 55))"
COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"

printf '\0asm\1\0\0\0matcher-fixture' >"$WORK_DIR/same.wasm"
printf '\0asm\1\0\0\0different-fixture' >"$WORK_DIR/other.wasm"

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/stellar" <<'STUB'
#!/usr/bin/env bash
# Minimal `stellar contract fetch` stub used by the verifier tests.
set -euo pipefail
if [ "${1:-}" != "contract" ] || [ "${2:-}" != "fetch" ]; then
  echo "stub: unsupported command: $*" >&2
  exit 64
fi
out_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-file)
      out_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$out_file" ] || {
  echo "stub: --out-file missing" >&2
  exit 64
}
if [ -n "${STUB_FAIL:-}" ]; then
  echo "stub: simulated RPC failure" >&2
  exit 1
fi
printf '%s' "${STUB_WASM:?}" >/dev/null
cp "${STUB_WASM:?}" "$out_file"
STUB
chmod +x "$WORK_DIR/bin/stellar"
STELLAR="$WORK_DIR/bin/stellar"

failures=0

pass() {
  echo "  ok: $1"
}

fail() {
  echo "  NOT OK: $1" >&2
  failures=$((failures + 1))
}

expect() {
  local name="$1" expected_status="$2" expected_text="$3"
  shift 3
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne "$expected_status" ]; then
    fail "$name: expected exit $expected_status, got $status"
    printf '%s\n' "$output" | sed 's/^/    /' >&2
    return
  fi
  if ! printf '%s' "$output" | grep -q -F -e "$expected_text"; then
    fail "$name: output does not contain '$expected_text'"
    printf '%s\n' "$output" | sed 's/^/    /' >&2
    return
  fi
  pass "$name"
}

echo "verify-deployment.sh"

expect "matching wasm reports MATCH and exits 0" 0 "RESULT: MATCH" \
  env STUB_WASM="$WORK_DIR/same.wasm" \
  "$VERIFY" --wasm "$WORK_DIR/same.wasm" --tag "$COMMIT" \
  --contract-id "$CONTRACT_ID" --network testnet --stellar "$STELLAR"

expect "different wasm reports MISMATCH and exits 1" 1 "RESULT: MISMATCH" \
  env STUB_WASM="$WORK_DIR/other.wasm" \
  "$VERIFY" --wasm "$WORK_DIR/same.wasm" --tag "$COMMIT" \
  --contract-id "$CONTRACT_ID" --network testnet --stellar "$STELLAR"

expect "RPC failures exit 2" 2 "could not fetch" \
  env STUB_FAIL=1 \
  "$VERIFY" --wasm "$WORK_DIR/same.wasm" --tag "$COMMIT" \
  --contract-id "$CONTRACT_ID" --network testnet --stellar "$STELLAR"

expect "malformed contract IDs are rejected" 2 "contract ID" \
  "$VERIFY" --wasm "$WORK_DIR/same.wasm" --tag "$COMMIT" \
  --contract-id "not-a-contract" --stellar "$STELLAR"

expect "unknown refs are rejected" 2 "git ref not found" \
  env STUB_WASM="$WORK_DIR/same.wasm" \
  "$VERIFY" --wasm "$WORK_DIR/same.wasm" --tag "v0.0.0-does-not-exist" \
  --contract-id "$CONTRACT_ID" --stellar "$STELLAR"

expect "missing --contract-id is a usage error" 2 "--contract-id is required" \
  "$VERIFY" --tag "$COMMIT" --stellar "$STELLAR"

expect "missing --wasm file is reported" 2 "--wasm file not found" \
  "$VERIFY" --wasm "$WORK_DIR/nope.wasm" --tag "$COMMIT" \
  --contract-id "$CONTRACT_ID" --stellar "$STELLAR"

if [ "$failures" -ne 0 ]; then
  echo "verify-deployment-test: $failures case(s) failed" >&2
  exit 1
fi

echo "verify-deployment-test: all cases passed"
