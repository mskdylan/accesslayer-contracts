#!/usr/bin/env bash
#
# Reproducibility check: build the same commit twice in two independent clean
# containers and compare the wasm hashes. Exits non-zero if they differ.
#
# This is what the `reproducible-build` CI job runs. Docker is required unless
# --local is passed, which uses the pinned rust-toolchain.toml on this machine
# (useful for contributors without Docker, but not authoritative).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/sha256.sh
. "$SCRIPT_DIR/lib/sha256.sh"

DEFAULT_IMAGE="accesslayer-wasm-builder:25.2.0-rust1.90.0"

REF="HEAD"
PACKAGE="creator-keys"
IMAGE="${BUILDER_IMAGE:-$DEFAULT_IMAGE}"
LOCAL_BUILD=0

usage() {
  cat <<'EOF'
Usage: scripts/repro-check.sh [options]

Options:
  --ref <ref>        Git ref to build twice. Default: HEAD.
  --package <name>   Cargo package to build. Default: creator-keys.
  --image <name>     Builder image tag. Default: $BUILDER_IMAGE, or
                     accesslayer-wasm-builder:25.2.0-rust1.90.0.
  --local            Build twice on this machine with the pinned toolchain
                     instead of in containers.
  -h, --help         Show this help.

Exit codes: 0 = identical hashes, 1 = hashes differ, 2 = error.
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

need_value() {
  if [ "$#" -lt 2 ]; then
    die "$1 requires a value"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ref)
      need_value "$@"
      REF="$2"
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
    --local)
      LOCAL_BUILD=1
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

command -v git >/dev/null 2>&1 || die "git is required"

COMMIT="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${REF}^{commit}")" ||
  die "git ref not found: $REF (try: git fetch --tags origin)"

ARTIFACT_NAME="$(printf '%s' "$PACKAGE" | tr '-' '_').wasm"

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

build_once() {
  local run_number="$1"
  local out_dir="$WORK_DIR/run$run_number"
  local log="$WORK_DIR/run$run_number.log"
  local args=(--ref "$COMMIT" --package "$PACKAGE" --out-dir "$out_dir" --image "$IMAGE")
  if [ "$LOCAL_BUILD" -eq 1 ]; then
    args+=(--local)
  fi
  if ! "$SCRIPT_DIR/build-release-wasm.sh" "${args[@]}" >"$log" 2>&1; then
    echo "error: build $run_number failed; output follows" >&2
    cat "$log" >&2
    exit 2
  fi
  sha256_of_file "$out_dir/$ARTIFACT_NAME"
}

echo "commit:  $COMMIT ($REF)"
echo "package: $PACKAGE"
echo "build 1: starting in a clean environment"
HASH_1="$(build_once 1)"
echo "build 1: $HASH_1"
echo "build 2: starting in a clean environment"
HASH_2="$(build_once 2)"
echo "build 2: $HASH_2"

if [ "$HASH_1" != "$HASH_2" ]; then
  echo "REPRODUCIBILITY FAILURE: the same commit produced different wasm" >&2
  echo "  build 1: $HASH_1" >&2
  echo "  build 2: $HASH_2" >&2
  echo "Run scripts/build-release-wasm.sh manually and diff the two wasm files." >&2
  exit 1
fi

if ! cmp -s "$WORK_DIR/run1/$ARTIFACT_NAME" "$WORK_DIR/run2/$ARTIFACT_NAME"; then
  echo "REPRODUCIBILITY FAILURE: hashes match but the wasm bytes differ" >&2
  exit 1
fi

echo "REPRODUCIBLE: both independent builds produced $HASH_1"
