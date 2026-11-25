#!/usr/bin/env bash
#
# Tests for scripts/verify-deployment.sh.
#
# Docker is replaced with a mock that emulates the pinned builder image: the
# build invocation writes a known wasm file and the `stellar contract fetch`
# invocation writes a configurable deployed wasm file (or fails). This exercises
# the script's validation, RPC response handling, hash comparison, and exit
# codes without needing Docker, a network, or a live contract.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY="$REPO_ROOT/scripts/verify-deployment.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

MOCK_BIN="$TMP_DIR/bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${MOCK_DOCKER_LOG:-/dev/null}"

subcommand="${1:-}"
if [ "$#" -gt 0 ]; then
  shift
fi

case "$subcommand" in
  build)
    exit "${MOCK_DOCKER_BUILD_EXIT:-0}"
    ;;
  run)
    entrypoint="build-wasm.sh"
    out_host=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -v | --volume)
          spec="$2"
          shift 2
          host="${spec%%:*}"
          rest="${spec#*:}"
          container="${rest%%:*}"
          if [ "$container" = "/out" ]; then
            out_host="$host"
          fi
          ;;
        --entrypoint)
          entrypoint="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done

    if [ -z "$out_host" ]; then
      echo "mock docker: no /out volume mount" >&2
      exit 90
    fi
    mkdir -p "$out_host"

    if [ "$entrypoint" = "stellar" ]; then
      if [ "${MOCK_RPC_EXIT:-0}" -ne 0 ]; then
        exit "${MOCK_RPC_EXIT}"
      fi
      if [ -n "${MOCK_RPC_WASM:-}" ] && [ -f "${MOCK_RPC_WASM}" ]; then
        cp "${MOCK_RPC_WASM}" "$out_host/deployed.wasm"
      else
        printf '%s' "${MOCK_RPC_CONTENT:-}" > "$out_host/deployed.wasm"
      fi
    else
      if [ "${MOCK_BUILD_EXIT:-0}" -ne 0 ]; then
        exit "${MOCK_BUILD_EXIT}"
      fi
      if [ "${MOCK_BUILD_NO_WASM:-0}" -eq 1 ]; then
        exit 0
      fi
      cp "${MOCK_BUILD_WASM}" "$out_host/creator_keys.wasm"
    fi
    ;;
  *)
    exit 0
    ;;
esac
MOCK
chmod +x "$MOCK_BIN/docker"

# Valid-shaped contract id (checksum is not validated locally; the RPC is).
CONTRACT_ID="C$(printf 'A%.0s' {1..55})"
RPC_URL="https://soroban-testnet.stellar.org"

printf '\0asm-local-build' > "$TMP_DIR/local.wasm"
printf '\0asm-other-deployment' > "$TMP_DIR/other.wasm"

COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"

PASS=0
FAIL=0
STATUS=0
OUTPUT=""

run_verify() {
  set +e
  OUTPUT="$(
    env \
      DOCKER="$MOCK_BIN/docker" \
      MOCK_DOCKER_LOG="$TMP_DIR/docker.log" \
      MOCK_BUILD_WASM="$TMP_DIR/local.wasm" \
      MOCK_RPC_WASM="$TMP_DIR/local.wasm" \
      "$@" \
      "$VERIFY" \
      --contract-id "$CONTRACT_ID" \
      --rpc-url "$RPC_URL" \
      --ref HEAD 2>&1
  )"
  STATUS=$?
  set -e
}

expect_exit() {
  local name="$1"
  local expected="$2"
  if [ "$STATUS" -eq "$expected" ]; then
    PASS=$((PASS + 1))
    printf 'PASS %-52s exit %s\n' "$name" "$STATUS"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %-52s expected exit %s, got %s\n' "$name" "$expected" "$STATUS"
    printf '%s\n' "$OUTPUT" | sed 's/^/      /'
  fi
}

expect_output() {
  local name="$1"
  local needle="$2"
  if printf '%s' "$OUTPUT" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    printf 'PASS %-52s output contains "%s"\n' "$name" "$needle"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %-52s output missing "%s"\n' "$name" "$needle"
    printf '%s\n' "$OUTPUT" | sed 's/^/      /'
  fi
}

# 1. Identical local and on-chain wasm -> MATCH, exit 0.
run_verify
expect_exit "identical hashes" 0
expect_output "identical hashes" "RESULT: MATCH"

# 2. Different local and on-chain wasm -> MISMATCH, exit 5.
run_verify MOCK_RPC_WASM="$TMP_DIR/other.wasm"
expect_exit "different hashes" 5
expect_output "different hashes" "RESULT: MISMATCH"

# 3. Missing required arguments -> usage error, exit 2.
set +e
OUTPUT="$(env DOCKER="$MOCK_BIN/docker" "$VERIFY" 2>&1)"
STATUS=$?
set -e
expect_exit "missing arguments" 2

# 4. Invalid contract id -> exit 2.
set +e
OUTPUT="$(env DOCKER="$MOCK_BIN/docker" "$VERIFY" --contract-id INVALID --rpc-url "$RPC_URL" 2>&1)"
STATUS=$?
set -e
expect_exit "invalid contract id" 2

# 5. Invalid RPC URL -> exit 2.
set +e
OUTPUT="$(env DOCKER="$MOCK_BIN/docker" "$VERIFY" --contract-id "$CONTRACT_ID" --rpc-url "not-a-url" 2>&1)"
STATUS=$?
set -e
expect_exit "invalid rpc url" 2

# 6. Missing Docker dependency -> exit 7.
set +e
OUTPUT="$(env DOCKER="$TMP_DIR/does-not-exist" "$VERIFY" --contract-id "$CONTRACT_ID" --rpc-url "$RPC_URL" 2>&1)"
STATUS=$?
set -e
expect_exit "missing docker dependency" 7

# 7. Build failure -> exit 3, never MATCH.
run_verify MOCK_BUILD_EXIT=1
expect_exit "build failure" 3
if printf '%s' "$OUTPUT" | grep -q "RESULT: MATCH"; then
  FAIL=$((FAIL + 1))
  echo "FAIL build failure must not report MATCH"
else
  PASS=$((PASS + 1))
  echo "PASS build failure does not report MATCH"
fi

# 8. Build produces no wasm -> exit 3.
run_verify MOCK_BUILD_NO_WASM=1
expect_exit "missing build artifact" 3

# 9. RPC failure -> exit 4.
run_verify MOCK_RPC_EXIT=1
expect_exit "rpc failure" 4

# 10. RPC returns HTML instead of wasm -> exit 4.
run_verify MOCK_RPC_WASM= MOCK_RPC_CONTENT="<html>error</html>"
expect_exit "malformed rpc response" 4
expect_output "malformed rpc response" "not a wasm module"

# 11. RPC returns empty body -> exit 4.
run_verify MOCK_RPC_WASM= MOCK_RPC_CONTENT=""
expect_exit "empty rpc response" 4

# 12. Release metadata hash disagrees with the local build -> exit 6.
METADATA_BAD="$TMP_DIR/releases-bad.json"
jq -n --arg commit "$COMMIT" '{
  schema_version: 1,
  repository: "https://example.invalid/repo",
  build: {},
  releases: [{
    tag: "HEAD",
    commit: $commit,
    wasm_sha256: ("0" * 64),
    package: "creator-keys",
    target: "wasm32v1-none",
    rust_toolchain: "1.89.0",
    soroban_sdk: "22.0.11",
    stellar_cli: "22.0.1",
    released_at: "2026-01-01T00:00:00Z"
  }]
}' > "$METADATA_BAD"
run_verify RELEASES_FILE="$METADATA_BAD"
expect_exit "inconsistent release metadata" 6

# 13. Consistent release metadata -> MATCH, exit 0.
LOCAL_HASH="$(sha256sum "$TMP_DIR/local.wasm" | awk '{print $1}')"
METADATA_GOOD="$TMP_DIR/releases-good.json"
jq -n --arg commit "$COMMIT" --arg hash "$LOCAL_HASH" '{
  schema_version: 1,
  repository: "https://example.invalid/repo",
  build: {},
  releases: [{
    tag: "HEAD",
    commit: $commit,
    wasm_sha256: $hash,
    package: "creator-keys",
    target: "wasm32v1-none",
    rust_toolchain: "1.89.0",
    soroban_sdk: "22.0.11",
    stellar_cli: "22.0.1",
    released_at: "2026-01-01T00:00:00Z"
  }]
}' > "$METADATA_GOOD"
run_verify RELEASES_FILE="$METADATA_GOOD"
expect_exit "consistent release metadata" 0
expect_output "consistent release metadata" "consistent with local build"

# 14. Unknown git ref -> exit 2.
set +e
OUTPUT="$(
  env DOCKER="$MOCK_BIN/docker" MOCK_BUILD_WASM="$TMP_DIR/local.wasm" \
    "$VERIFY" --contract-id "$CONTRACT_ID" --rpc-url "$RPC_URL" --ref no-such-ref 2>&1
)"
STATUS=$?
set -e
expect_exit "unknown git ref" 2

echo
printf 'verify-deployment tests: %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
