#!/usr/bin/env bash
#
# Tests for scripts/generate-release-metadata.py.
#
# Covers pin validation (releases.json vs Dockerfile / rust-toolchain.toml /
# Cargo.lock), deterministic metadata generation, ledger updates and conflict
# rejection. No network or Docker access is required.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
. "$REPO_ROOT/scripts/lib/sha256.sh"
GENERATOR="$REPO_ROOT/scripts/generate-release-metadata.py"

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
WASM="$WORK_DIR/creator_keys.wasm"
printf '\0asm\1\0\0\0release-metadata-fixture' >"$WASM"
WASM_HASH="$(sha256_of_file "$WASM")"
WASM_BYTES="$(wc -c <"$WASM" | tr -d ' ')"

failures=0
pass() { echo "  ok: $1"; }
fail() {
  echo "  NOT OK: $1" >&2
  failures=$((failures + 1))
}

expect_status() {
  local name="$1" expected="$2"
  shift 2
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne "$expected" ]; then
    fail "$name: expected exit $expected, got $status"
    printf '%s\n' "$output" | sed 's/^/    /' >&2
    return 1
  fi
  pass "$name"
  printf '%s' "$output"
}

echo "generate-release-metadata.py"

expect_status "committed releases.json validates" 0 \
  python3 "$GENERATOR" validate >/dev/null

expect_status "metadata generation succeeds" 0 \
  python3 "$GENERATOR" generate \
  --tag v0.0.0-test \
  --commit "$COMMIT" \
  --wasm "creator-keys=$WASM" \
  --out "$WORK_DIR/metadata-1.json" >/dev/null

expect_status "generation is deterministic" 0 \
  python3 "$GENERATOR" generate \
  --tag v0.0.0-test \
  --commit "$COMMIT" \
  --wasm "creator-keys=$WASM" \
  --out "$WORK_DIR/metadata-2.json" >/dev/null

if cmp -s "$WORK_DIR/metadata-1.json" "$WORK_DIR/metadata-2.json"; then
  pass "two generations produced identical bytes"
else
  fail "two generations produced different bytes"
fi

if python3 - "$WORK_DIR/metadata-1.json" "$WASM_HASH" "$WASM_BYTES" "$COMMIT" <<'PY'
import json
import sys

path, expected_hash, expected_bytes, commit = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    metadata = json.load(handle)
assert metadata["schemaVersion"] == 1, metadata["schemaVersion"]
assert metadata["tag"] == "v0.0.0-test", metadata["tag"]
assert metadata["commit"] == commit, metadata["commit"]
assert metadata["target"] == "wasm32v1-none", metadata["target"]
assert metadata["build"]["rust"], metadata["build"]
assert metadata["build"]["sorobanCli"], metadata["build"]
contract = metadata["contracts"][0]
assert contract["package"] == "creator-keys", contract
assert contract["sha256"] == expected_hash, contract
assert contract["bytes"] == int(expected_bytes), contract
PY
then
  pass "metadata records tag, commit, hash, tool versions"
else
  fail "metadata fields are wrong"
fi

expect_status "ledger update succeeds" 0 \
  python3 "$GENERATOR" generate \
  --tag v0.0.0-test \
  --commit "$COMMIT" \
  --wasm "creator-keys=$WASM" \
  --out "$WORK_DIR/metadata-3.json" \
  --update "$WORK_DIR/releases.json" >/dev/null

expect_status "updated ledger validates" 0 \
  python3 "$GENERATOR" validate --releases "$WORK_DIR/releases.json" >/dev/null

if grep -q "\"sha256\": \"$WASM_HASH\"" "$WORK_DIR/releases.json"; then
  pass "updated ledger records the wasm hash"
else
  fail "updated ledger is missing the wasm hash"
fi

printf '\0asm\1\0\0\0different-release-bytes' >"$WORK_DIR/other.wasm"
expect_status "re-recording a tag with different bytes is rejected" 1 \
  python3 "$GENERATOR" generate \
  --tag v0.0.0-test \
  --commit "$COMMIT" \
  --wasm "creator-keys=$WORK_DIR/other.wasm" \
  --out "$WORK_DIR/metadata-4.json" \
  --update "$WORK_DIR/releases.json" >/dev/null

python3 - "$REPO_ROOT/releases.json" "$WORK_DIR/drifted.json" <<'PY'
import json
import sys

source, target = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    document = json.load(handle)
document["build"]["sorobanSdk"] = "0.0.0"
with open(target, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2)
PY
expect_status "toolchain drift is rejected" 1 \
  python3 "$GENERATOR" validate --check-pins --releases "$WORK_DIR/drifted.json" >/dev/null

drift_output="$(python3 "$GENERATOR" validate --check-pins --releases "$WORK_DIR/drifted.json" 2>&1 || true)"
case "$drift_output" in
  *sorobanSdk*) pass "drift error names the mismatched pin" ;;
  *) fail "drift error does not name the mismatched pin"; printf '%s\n' "$drift_output" | sed 's/^/    /' >&2 ;;
esac

if [ "$failures" -ne 0 ]; then
  echo "release-metadata-test: $failures case(s) failed" >&2
  exit 1
fi

echo "release-metadata-test: all cases passed"
