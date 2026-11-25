#!/usr/bin/env bash
#
# Build a release wasm from an exact git ref in a clean source tree.
#
# By default the build runs inside Dockerfile.release (the pinned release
# environment). Use --local only when Docker is unavailable; the local build
# still uses the pinned rust-toolchain.toml and the same RUSTFLAGS remapping,
# but it is not a verified container environment.
#
# The source is exported with `git archive`, so uncommitted changes are never
# included in a build.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REF="HEAD"
OUT_DIR="$REPO_ROOT/target/reproducible"
PACKAGE="creator-keys"
IMAGE="${BUILDER_IMAGE:-accesslayer-wasm-builder:local}"
LOCAL_BUILD=0
BUILD_IMAGE=1
DOCKER="${DOCKER:-docker}"

usage() {
  cat <<'EOF'
Usage: scripts/build-wasm.sh [options]

Build the release wasm for a commit/tag in the pinned build environment.

Options:
  --ref <ref>            Git ref (tag, branch, or commit) to build. Default: HEAD
  --out-dir <dir>        Directory for the wasm and .sha256 sidecar.
                         Default: target/reproducible
  --package <name>       Cargo package to build. Default: creator-keys
  --image <name>         Builder image tag. Default: accesslayer-wasm-builder:local
  --local                Build on this machine with the pinned rust-toolchain.toml
                         instead of Docker.
  --skip-image-build     Do not rebuild the Docker image (it must already exist).
  -h, --help             Show this help.

Environment:
  BUILDER_IMAGE          Default value for --image
  DOCKER                 Docker binary to use (default: docker)

Output:
  Prints the built wasm path and its SHA-256. Exit code 0 on success.
EOF
}

need_value() {
  if [ "$#" -lt 2 ]; then
    echo "error: $1 requires a value" >&2
    usage >&2
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ref)
      need_value "$@"
      REF="$2"
      shift 2
      ;;
    --out-dir)
      need_value "$@"
      OUT_DIR="$2"
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
    --skip-image-build)
      BUILD_IMAGE=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$LOCAL_BUILD" -eq 0 ] && ! command -v "$DOCKER" >/dev/null 2>&1; then
  echo "error: docker is required for a container build (or pass --local)" >&2
  exit 7
fi

if ! command -v git >/dev/null 2>&1; then
  echo "error: git is required to export the requested ref" >&2
  exit 7
fi

COMMIT="$(git -C "$REPO_ROOT" rev-parse --verify "${REF}^{commit}" 2>/dev/null)" || {
  echo "error: git ref not found: $REF" >&2
  exit 2
}

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

SOURCE_DIR="$WORK_DIR/source"
mkdir -p "$SOURCE_DIR"
git -C "$REPO_ROOT" archive --format=tar "$COMMIT" | tar -x -C "$SOURCE_DIR"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

ARTIFACT_NAME="$(printf '%s' "$PACKAGE" | tr '-' '_').wasm"

if [ "$LOCAL_BUILD" -eq 1 ]; then
  CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"
  RUSTUP_HOME_DIR="${RUSTUP_HOME:-$HOME/.rustup}"
  export RUSTFLAGS="--remap-path-prefix=$SOURCE_DIR=/source --remap-path-prefix=$CARGO_HOME_DIR=/cargo --remap-path-prefix=$RUSTUP_HOME_DIR=/rustup"
  export SOURCE_DIR="$SOURCE_DIR"
  export OUT_DIR
  export WASM_PACKAGE="$PACKAGE"
  export CARGO_TARGET_DIR="$WORK_DIR/target"
  "$REPO_ROOT/docker/build-wasm.sh"
else
  if [ "$BUILD_IMAGE" -eq 1 ]; then
    "$DOCKER" build \
      --file "$REPO_ROOT/Dockerfile.release" \
      --tag "$IMAGE" \
      "$REPO_ROOT" >&2
  fi
  "$DOCKER" run --rm \
    --volume "$SOURCE_DIR:/source:ro" \
    --volume "$OUT_DIR:/out" \
    --env "WASM_PACKAGE=$PACKAGE" \
    "$IMAGE"
fi

ARTIFACT="$OUT_DIR/$ARTIFACT_NAME"
if [ ! -f "$ARTIFACT" ]; then
  echo "error: build did not produce $ARTIFACT" >&2
  exit 3
fi

HASH="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
printf 'ref: %s (%s)\n' "$REF" "$COMMIT"
printf 'wasm: %s\n' "$ARTIFACT"
printf 'sha256: %s\n' "$HASH"
