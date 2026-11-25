#!/usr/bin/env bash
#
# Tests for scripts/validate-releases.py.
#
# The repository's releases.json must validate, and malformed metadata
# (wrong pins, bad hashes, duplicate tags, missing fields) must be rejected.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/validate-releases.py"
BASE_FILE="$REPO_ROOT/releases.json"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0
STATUS=0
OUTPUT=""

run_validator() {
  set +e
  OUTPUT="$(python3 "$VALIDATOR" --repo-root "$REPO_ROOT" --file "$1" 2>&1)"
  STATUS=$?
  set -e
}

expect_exit() {
  local name="$1"
  local expected="$2"
  if [ "$STATUS" -eq "$expected" ]; then
    PASS=$((PASS + 1))
    printf 'PASS %-48s exit %s\n' "$name" "$STATUS"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %-48s expected exit %s, got %s\n' "$name" "$expected" "$STATUS"
    printf '%s\n' "$OUTPUT" | sed 's/^/      /'
  fi
}

# 1. The committed metadata is valid.
run_validator "$BASE_FILE"
expect_exit "committed releases.json is valid" 0

# 2. A fully populated valid release entry passes.
VALID_ENTRY="$TMP_DIR/valid.json"
jq '.releases = [{
  "tag": "v0.1.0",
  "commit": "0123456789abcdef0123456789abcdef01234567",
  "wasm_sha256": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
  "package": "creator-keys",
  "target": "wasm32v1-none",
  "rust_toolchain": "1.89.0",
  "soroban_sdk": "22.0.11",
  "stellar_cli": "22.0.1",
  "released_at": "2026-01-01T00:00:00Z",
  "contracts": [{"network": "testnet", "contract_id": "CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB"}]
}]' "$BASE_FILE" > "$VALID_ENTRY"
# Contract ids must be exactly 56 characters; fix the fixture above.
jq '.releases[0].contracts[0].contract_id = ("C" + ("A" * 55))' "$VALID_ENTRY" > "$VALID_ENTRY.tmp" \
  && mv "$VALID_ENTRY.tmp" "$VALID_ENTRY"
run_validator "$VALID_ENTRY"
expect_exit "valid release entry" 0

# 3. A toolchain pin that disagrees with rust-toolchain.toml is rejected.
jq '.build.rust_toolchain = "9.9.9"' "$BASE_FILE" > "$TMP_DIR/bad-rust.json"
run_validator "$TMP_DIR/bad-rust.json"
expect_exit "mismatched Rust pin" 1

# 4. A CLI pin that disagrees with Dockerfile.release is rejected.
jq '.build.stellar_cli = "0.0.0"' "$BASE_FILE" > "$TMP_DIR/bad-cli.json"
run_validator "$TMP_DIR/bad-cli.json"
expect_exit "mismatched Stellar CLI pin" 1

# 5. A placeholder wasm hash is rejected.
jq '.releases[0].wasm_sha256 = ("0" * 64)' "$VALID_ENTRY" > "$TMP_DIR/zero-hash.json"
run_validator "$TMP_DIR/zero-hash.json"
expect_exit "placeholder wasm hash" 1

# 6. A malformed wasm hash is rejected.
jq '.releases[0].wasm_sha256 = "not-a-hash"' "$VALID_ENTRY" > "$TMP_DIR/bad-hash.json"
run_validator "$TMP_DIR/bad-hash.json"
expect_exit "malformed wasm hash" 1

# 7. Duplicate tags are rejected.
jq '.releases += [.releases[0]]' "$VALID_ENTRY" > "$TMP_DIR/duplicate.json"
run_validator "$TMP_DIR/duplicate.json"
expect_exit "duplicate release tag" 1

# 8. A missing required release field is rejected.
jq 'del(.releases[0].commit)' "$VALID_ENTRY" > "$TMP_DIR/missing.json"
run_validator "$TMP_DIR/missing.json"
expect_exit "missing commit field" 1

# 9. An invalid optional contract id is rejected.
jq '.releases[0].contracts[0].contract_id = "CINVALID"' "$VALID_ENTRY" > "$TMP_DIR/bad-contract.json"
run_validator "$TMP_DIR/bad-contract.json"
expect_exit "invalid contract id" 1

# 10. Invalid JSON is rejected.
printf '{not json' > "$TMP_DIR/broken.json"
run_validator "$TMP_DIR/broken.json"
expect_exit "invalid JSON" 1

echo
printf 'release metadata tests: %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
