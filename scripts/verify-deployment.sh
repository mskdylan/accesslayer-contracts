#!/usr/bin/env bash
#
# Verify that a deployed Soroban contract matches a tagged source commit.
#
# The script:
#   1. exports the requested git ref into a clean tree,
#   2. builds it in the pinned Dockerfile.release environment (or --local),
#   3. fetches the deployed contract's wasm from the Soroban RPC with the pinned
#      Stellar CLI,
#   4. hashes both wasm files with SHA-256 and compares them.
#
# Verification needs no account, key, or funded identity: it only reads public
# RPC state and builds public source.
#
# Exit codes:
#   0  MATCH: local build hash equals the on-chain wasm hash
#   1  unexpected/internal failure
#   2  invalid usage or invalid input (contract id, RPC URL, ref, flag)
#   3  local build failed or produced no wasm
#   4  RPC retrieval failed or returned something that is not wasm
#   5  MISMATCH: hashes differ
#   6  release metadata (releases.json) is inconsistent with the local build
#   7  a required command is missing

set -euo pipefail

EXIT_OK=0
EXIT_USAGE=2
EXIT_BUILD=3
EXIT_RPC=4
EXIT_MISMATCH=5
EXIT_METADATA=6
EXIT_DEPENDENCY=7

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONTRACT_ID="${CONTRACT_ID:-}"
RPC_URL="${RPC_URL:-}"
RELEASE_REF="${RELEASE_REF:-HEAD}"
NETWORK_PASSPHRASE="${NETWORK_PASSPHRASE:-Test SDF Network ; September 2015}"
WASM_PACKAGE="${WASM_PACKAGE:-creator-keys}"
BUILDER_IMAGE="${BUILDER_IMAGE:-accesslayer-wasm-builder:local}"
RELEASES_FILE="${RELEASES_FILE:-$REPO_ROOT/releases.json}"
LOCAL_BUILD=0
DOCKER="${DOCKER:-docker}"

usage() {
  cat <<'EOF'
Usage: scripts/verify-deployment.sh --contract-id <ID> --rpc-url <URL> [options]

Builds a tagged source commit in the pinned build environment and compares its
wasm SHA-256 with the wasm hash of a deployed Soroban contract retrieved from a
public RPC endpoint.

Required (flag or environment variable):
  -c, --contract-id <ID>        Deployed contract id (56-char StrKey, starts "C")
                                Environment: CONTRACT_ID
  -r, --rpc-url <URL>           Soroban RPC endpoint (http or https)
                                Environment: RPC_URL

Options:
  -t, --ref <ref>               Release tag/branch/commit to build.
                                Default: HEAD. Environment: RELEASE_REF
      --network-passphrase <p>  Network passphrase for the RPC.
                                Default: testnet passphrase.
                                Environment: NETWORK_PASSPHRASE
      --package <name>          Cargo package to build. Default: creator-keys
                                Environment: WASM_PACKAGE
      --image <name>            Pinned builder image tag.
                                Default: accesslayer-wasm-builder:local
                                Environment: BUILDER_IMAGE
      --releases-file <path>    Release metadata to cross-check.
                                Default: <repo>/releases.json
                                Environment: RELEASES_FILE
      --local                   Build on this machine instead of Docker. The
                                pinned rust-toolchain.toml is still used, but
                                the pinned container is NOT verified.
  -h, --help                    Show this help.

Examples:
  scripts/verify-deployment.sh \
    --contract-id C... \
    --rpc-url https://soroban-testnet.stellar.org \
    --ref v1.0.0

  CONTRACT_ID=C... RPC_URL=https://soroban-testnet.stellar.org \
    scripts/verify-deployment.sh --ref v1.0.0

Exit codes: 0 MATCH, 2 usage, 3 build, 4 RPC, 5 MISMATCH, 6 metadata, 7 dependency.
EOF
}

die() {
  local code="$1"
  shift
  echo "error: $*" >&2
  exit "$code"
}

need_value() {
  if [ "$#" -lt 2 ]; then
    usage >&2
    die "$EXIT_USAGE" "$1 requires a value"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -c | --contract-id)
      need_value "$@"
      CONTRACT_ID="$2"
      shift 2
      ;;
    -r | --rpc-url)
      need_value "$@"
      RPC_URL="$2"
      shift 2
      ;;
    -t | --ref | --tag)
      need_value "$@"
      RELEASE_REF="$2"
      shift 2
      ;;
    --network-passphrase)
      need_value "$@"
      NETWORK_PASSPHRASE="$2"
      shift 2
      ;;
    --package)
      need_value "$@"
      WASM_PACKAGE="$2"
      shift 2
      ;;
    --image)
      need_value "$@"
      BUILDER_IMAGE="$2"
      shift 2
      ;;
    --releases-file)
      need_value "$@"
      RELEASES_FILE="$2"
      shift 2
      ;;
    --local)
      LOCAL_BUILD=1
      shift
      ;;
    -h | --help)
      usage
      exit "$EXIT_OK"
      ;;
    *)
      usage >&2
      die "$EXIT_USAGE" "unknown option: $1"
      ;;
  esac
done

if [ -z "$CONTRACT_ID" ] || [ -z "$RPC_URL" ]; then
  usage >&2
  die "$EXIT_USAGE" "--contract-id and --rpc-url are required"
fi

if ! [[ "$CONTRACT_ID" =~ ^C[A-Z2-7]{55}$ ]]; then
  die "$EXIT_USAGE" "invalid contract id '$CONTRACT_ID': expected a 56-character contract StrKey starting with 'C'"
fi

if ! [[ "$RPC_URL" =~ ^https?://[^[:space:]]+$ ]]; then
  die "$EXIT_USAGE" "invalid RPC URL '$RPC_URL': expected an http:// or https:// URL"
fi

if [ -z "$NETWORK_PASSPHRASE" ]; then
  die "$EXIT_USAGE" "network passphrase must not be empty"
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "$EXIT_DEPENDENCY" "required command not found: $1"
  fi
}

require_cmd git
require_cmd sha256sum
require_cmd od
require_cmd mktemp
require_cmd jq

if [ "$LOCAL_BUILD" -eq 1 ]; then
  require_cmd cargo
  require_cmd stellar
else
  require_cmd "$DOCKER"
fi

COMMIT="$(git -C "$REPO_ROOT" rev-parse --verify "${RELEASE_REF}^{commit}" 2>/dev/null)" || {
  die "$EXIT_USAGE" "git ref not found: $RELEASE_REF"
}

WORK_DIR="$(mktemp -d)"
cleanup() {
  # shellcheck disable=SC2317
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

LOCAL_OUT="$WORK_DIR/local"
DEPLOYED_WASM="$WORK_DIR/deployed.wasm"
ARTIFACT_NAME="$(printf '%s' "$WASM_PACKAGE" | tr '-' '_').wasm"

echo "repo:        $REPO_ROOT"
echo "ref:         $RELEASE_REF ($COMMIT)"
echo "package:     $WASM_PACKAGE"
echo "contract id: $CONTRACT_ID"
echo "rpc url:     $RPC_URL"
echo "environment: $([ "$LOCAL_BUILD" -eq 1 ] && echo 'local (pinned rust-toolchain.toml)' || echo "docker ($BUILDER_IMAGE)")"
echo

echo "Building $RELEASE_REF..."
BUILD_ARGS=(--ref "$RELEASE_REF" --out-dir "$LOCAL_OUT" --package "$WASM_PACKAGE" --image "$BUILDER_IMAGE")
if [ "$LOCAL_BUILD" -eq 1 ]; then
  BUILD_ARGS+=(--local)
fi
if ! "$REPO_ROOT/scripts/build-wasm.sh" "${BUILD_ARGS[@]}"; then
  die "$EXIT_BUILD" "reproducible build failed; cannot verify deployment"
fi

LOCAL_WASM="$LOCAL_OUT/$ARTIFACT_NAME"
if [ ! -s "$LOCAL_WASM" ]; then
  die "$EXIT_BUILD" "build did not produce a non-empty $LOCAL_WASM"
fi
LOCAL_HASH="$(sha256sum "$LOCAL_WASM" | awk '{print $1}')"
echo "local wasm:  $LOCAL_WASM"
echo "local sha256: $LOCAL_HASH"
echo

# Cross-check against release metadata when this commit/tag is recorded there.
if [ -f "$RELEASES_FILE" ]; then
  METADATA_ENTRY="$(jq -c \
    --arg tag "$RELEASE_REF" \
    --arg commit "$COMMIT" \
    --arg pkg "$WASM_PACKAGE" \
    '(.releases // [])[] | select((.tag == $tag or .commit == $commit) and .package == $pkg)' \
    "$RELEASES_FILE" 2>/dev/null | head -n 1)"

  if [ -n "$METADATA_ENTRY" ]; then
    RECORDED_HASH="$(printf '%s' "$METADATA_ENTRY" | jq -r '.wasm_sha256 // ""')"
    RECORDED_COMMIT="$(printf '%s' "$METADATA_ENTRY" | jq -r '.commit // ""')"
    echo "release metadata: $RELEASES_FILE"
    echo "recorded sha256:  $RECORDED_HASH"
    if [ "$RECORDED_COMMIT" != "$COMMIT" ] && [ "$(printf '%s' "$METADATA_ENTRY" | jq -r '.tag // ""')" != "$RELEASE_REF" ]; then
      die "$EXIT_METADATA" "release metadata entry does not match ref $RELEASE_REF ($COMMIT)"
    fi
    if [ -z "$RECORDED_HASH" ] || [ "$RECORDED_HASH" != "$LOCAL_HASH" ]; then
      die "$EXIT_METADATA" "release metadata hash does not match the local build"
    fi
    echo "release metadata: consistent with local build"
    echo
  fi
fi

echo "Fetching deployed wasm from $RPC_URL..."
if [ "$LOCAL_BUILD" -eq 1 ]; then
  if ! stellar contract fetch \
    --contract-id "$CONTRACT_ID" \
    --rpc-url "$RPC_URL" \
    --network-passphrase "$NETWORK_PASSPHRASE" \
    --out-file "$DEPLOYED_WASM"; then
    die "$EXIT_RPC" "failed to retrieve the deployed contract wasm from the RPC"
  fi
else
  if ! "$DOCKER" run --rm \
    --entrypoint stellar \
    --volume "$WORK_DIR:/out" \
    "$BUILDER_IMAGE" \
    contract fetch \
    --contract-id "$CONTRACT_ID" \
    --rpc-url "$RPC_URL" \
    --network-passphrase "$NETWORK_PASSPHRASE" \
    --out-file /out/deployed.wasm; then
    die "$EXIT_RPC" "failed to retrieve the deployed contract wasm from the RPC"
  fi
fi

if [ ! -s "$DEPLOYED_WASM" ]; then
  die "$EXIT_RPC" "RPC returned an empty response for contract $CONTRACT_ID"
fi

MAGIC="$(od -An -tx1 -N4 "$DEPLOYED_WASM" | tr -d ' \n')"
if [ "$MAGIC" != "0061736d" ]; then
  die "$EXIT_RPC" "RPC response is not a wasm module (magic bytes: $MAGIC)"
fi

ONCHAIN_HASH="$(sha256sum "$DEPLOYED_WASM" | awk '{print $1}')"
echo "on-chain sha256: $ONCHAIN_HASH"
echo

if [ "$LOCAL_HASH" = "$ONCHAIN_HASH" ]; then
  echo "RESULT: MATCH"
  echo "The deployed contract wasm matches the build of $RELEASE_REF ($COMMIT)."
  exit "$EXIT_OK"
fi

echo "RESULT: MISMATCH" >&2
echo "  local build: $LOCAL_HASH ($RELEASE_REF / $COMMIT)" >&2
echo "  on-chain:    $ONCHAIN_HASH ($CONTRACT_ID)" >&2
echo "Do not trust this deployment until the difference is explained." >&2
exit "$EXIT_MISMATCH"
