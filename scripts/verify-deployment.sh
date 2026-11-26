#!/usr/bin/env bash
#
# Verify that a deployed Soroban contract was built from a given tag.
#
#   1. Export the tagged commit and build its wasm in the pinned builder image
#      (Dockerfile), so the local hash does not depend on this machine.
#   2. Fetch the deployed wasm from the network's Soroban RPC endpoint.
#   3. Compare SHA-256 hashes and report MATCH or MISMATCH.
#
# No secrets are required: both steps are read-only and use public RPC.
#
# Exit codes: 0 = MATCH, 1 = MISMATCH, 2 = usage or infrastructure error.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/sha256.sh
. "$SCRIPT_DIR/lib/sha256.sh"

DEFAULT_IMAGE="accesslayer-wasm-builder:25.2.0-rust1.90.0"

TAG=""
CONTRACT_ID=""
NETWORK="testnet"
RPC_URL=""
PACKAGE="creator-keys"
IMAGE="${BUILDER_IMAGE:-$DEFAULT_IMAGE}"
STELLAR_BIN="${STELLAR_BIN:-}"
WASM_FILE=""
SKIP_IMAGE_BUILD=0
DOCKER="${DOCKER:-docker}"
export DOCKER

usage() {
  cat <<'EOF'
Usage: scripts/verify-deployment.sh --tag <tag> --contract-id <C...> [options]

Required:
  --tag <tag>            Release tag (or any git ref) to rebuild and compare.
  --contract-id <id>     Deployed contract ID (starts with C).

Options:
  --network <name>       Stellar network name understood by the CLI
                         (testnet, futurenet, mainnet, or a configured alias).
                         Default: testnet.
  --rpc-url <url>        Override the network's RPC endpoint. Read-only access
                         is enough; no API key or secret is required.
  --package <name>       Cargo package to build. Default: creator-keys.
  --image <name>         Builder image tag. Default: $BUILDER_IMAGE, or
                         accesslayer-wasm-builder:25.2.0-rust1.90.0.
  --wasm <file>          Verify this already-built wasm instead of building the
                         tag. The on-chain fetch still uses --stellar or the
                         pinned container image.
  --stellar <path>       Use this local stellar CLI to fetch the on-chain wasm
                         instead of the pinned container image.
  --skip-image-build     Reuse an existing builder image instead of rebuilding
                         it from the tag's Dockerfile.
  -h, --help             Show this help.

Environment:
  BUILDER_IMAGE, STELLAR_BIN, DOCKER

Exit codes:
  0  MATCH     local build hash equals the deployed wasm hash
  1  MISMATCH  hashes differ
  2  usage or infrastructure error (build failed, RPC unreachable, ...)
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

note() {
  printf '%s\n' "$*" >&2
}

need_value() {
  if [ "$#" -lt 2 ]; then
    die "$1 requires a value"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag)
      need_value "$@"
      TAG="$2"
      shift 2
      ;;
    --contract-id)
      need_value "$@"
      CONTRACT_ID="$2"
      shift 2
      ;;
    --network)
      need_value "$@"
      NETWORK="$2"
      shift 2
      ;;
    --rpc-url)
      need_value "$@"
      RPC_URL="$2"
      shift 2
      ;;
    --package)
      need_value "$@"
      PACKAGE="$2"
      shift 2
      ;;
    --image)
      need_value "$@"
      IMAGE="$2"
      shift 2
      ;;
    --wasm)
      need_value "$@"
      WASM_FILE="$2"
      shift 2
      ;;
    --stellar)
      need_value "$@"
      STELLAR_BIN="$2"
      shift 2
      ;;
    --skip-image-build)
      SKIP_IMAGE_BUILD=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (see --help)"
      ;;
  esac
done

[ -n "$TAG" ] || die "--tag is required"
[ -n "$CONTRACT_ID" ] || die "--contract-id is required"

if ! printf '%s' "$CONTRACT_ID" | grep -Eq '^C[A-Z2-7]{55}$'; then
  die "--contract-id does not look like a Stellar contract ID (C... / 56 base32 characters): $CONTRACT_ID"
fi

case "$PACKAGE" in
  *[!a-z0-9-]* | "")
    die "invalid package name: $PACKAGE"
    ;;
esac

command -v git >/dev/null 2>&1 || die "git is required"
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
  die "sha256sum (coreutils) or shasum is required"

cd "$REPO_ROOT"

COMMIT="$(git rev-parse --verify --quiet "${TAG}^{commit}")" ||
  die "git ref not found: $TAG (run: git fetch --tags origin)"
if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
  note "Verifying tag $TAG ($COMMIT)"
else
  note "warning: $TAG is not a tag in this checkout; verifying commit $COMMIT"
fi

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------- local build
if [ -n "$WASM_FILE" ]; then
  [ -f "$WASM_FILE" ] || die "--wasm file not found: $WASM_FILE"
  LOCAL_WASM="$(cd -- "$(dirname -- "$WASM_FILE")" && pwd)/$(basename -- "$WASM_FILE")"
  note "Using prebuilt wasm $LOCAL_WASM (build step skipped)"
else
  note "Building $PACKAGE from $TAG in the pinned builder image"
  build_args=(--ref "$COMMIT" --package "$PACKAGE" --out-dir "$WORK_DIR/local" --image "$IMAGE")
  if [ "$SKIP_IMAGE_BUILD" -eq 1 ]; then
    build_args+=(--skip-image-build)
  fi
  "$SCRIPT_DIR/build-release-wasm.sh" "${build_args[@]}" >&2
  LOCAL_WASM="$WORK_DIR/local/$(printf '%s' "$PACKAGE" | tr '-' '_').wasm"
fi
[ -s "$LOCAL_WASM" ] || die "local wasm is missing or empty: $LOCAL_WASM"

# ------------------------------------------------------- on-chain wasm fetch
ONCHAIN_DIR="$WORK_DIR/onchain"
mkdir -p "$ONCHAIN_DIR"
ONCHAIN_NAME="onchain_$(printf '%s' "$PACKAGE" | tr '-' '_').wasm"
ONCHAIN_WASM="$ONCHAIN_DIR/$ONCHAIN_NAME"

fetch_args=(contract fetch --id "$CONTRACT_ID" --network "$NETWORK")
if [ -n "$RPC_URL" ]; then
  fetch_args+=(--rpc-url "$RPC_URL")
fi

if [ -n "$STELLAR_BIN" ]; then
  command -v "$STELLAR_BIN" >/dev/null 2>&1 ||
    die "stellar CLI not found: $STELLAR_BIN"
  note "Fetching deployed wasm for $CONTRACT_ID from $NETWORK with $STELLAR_BIN"
  "$STELLAR_BIN" "${fetch_args[@]}" --out-file "$ONCHAIN_WASM" ||
    die "could not fetch contract $CONTRACT_ID from network $NETWORK (is the contract ID and network correct?)"
else
  command -v "$DOCKER" >/dev/null 2>&1 ||
    die "docker is required to fetch the on-chain wasm (or pass --stellar <path>)"
  if ! "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1; then
    [ -f "$REPO_ROOT/Dockerfile" ] ||
      die "builder image $IMAGE not found and this checkout has no Dockerfile to build it"
    note "Builder image $IMAGE not found; building it from $REPO_ROOT/Dockerfile"
    "$DOCKER" build --file "$REPO_ROOT/Dockerfile" --tag "$IMAGE" "$REPO_ROOT" >&2
  fi
  note "Fetching deployed wasm for $CONTRACT_ID from $NETWORK with the pinned stellar CLI"
  # The image runs as a non-root user that may not share this host uid.
  chmod 0777 "$ONCHAIN_DIR"
  "$DOCKER" run --rm --entrypoint stellar \
    --volume "$ONCHAIN_DIR:/out" \
    "$IMAGE" "${fetch_args[@]}" --out-file "/out/$ONCHAIN_NAME" ||
    die "could not fetch contract $CONTRACT_ID from network $NETWORK (is the contract ID and network correct?)"
fi
[ -s "$ONCHAIN_WASM" ] || die "fetched on-chain wasm is empty: $ONCHAIN_WASM"

# ----------------------------------------------------------------- comparison
LOCAL_HASH="$(sha256_of_file "$LOCAL_WASM")"
ONCHAIN_HASH="$(sha256_of_file "$ONCHAIN_WASM")"

cat <<EOF

Release tag:       $TAG
Commit:            $COMMIT
Package:           $PACKAGE
Network:           $NETWORK${RPC_URL:+ ($RPC_URL)}
Local wasm:        $LOCAL_WASM
Local SHA-256:     $LOCAL_HASH
On-chain wasm:     $ONCHAIN_WASM
On-chain SHA-256:  $ONCHAIN_HASH

EOF

if [ "$LOCAL_HASH" = "$ONCHAIN_HASH" ]; then
  echo "RESULT: MATCH"
  echo "The deployed contract's wasm matches a reproducible build of $TAG."
  exit 0
fi

cat >&2 <<EOF
RESULT: MISMATCH
The wasm rebuilt from $TAG does not match the bytecode deployed at
$CONTRACT_ID on $NETWORK.

Check, in order:
  1. $TAG is the tag that was actually released for this contract
     (git show $TAG).
  2. Cargo.lock at that tag was not modified after the release build.
  3. The build used this repository's pinned builder image (Dockerfile), with
     the Rust and Stellar CLI versions recorded in releases.json.
  4. The deployed wasm was not post-processed after the reproducible build,
     for example optimized with \`stellar contract optimize\` or rebuilt from a
     different commit.
  5. The local tree is clean and the tag was fetched from the canonical remote
     (git fetch --tags origin).
EOF
exit 1
