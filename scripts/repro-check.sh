#!/usr/bin/env bash
#
# Build the same commit twice, in two separate clean source trees, and fail if
# the wasm hashes differ.
#
# In CI each build runs in its own freshly started container of the pinned
# builder image; locally it uses the same image (or --local with the pinned
# rust-toolchain.toml).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REF="HEAD"
IMAGE="${BUILDER_IMAGE:-accesslayer-wasm-builder:local}"
PACKAGE="creator-keys"
LOCAL_BUILD=0
BUILD_IMAGE=1
DOCKER="${DOCKER:-docker}"

usage() {
  cat <<'EOF'
Usage: scripts/repro-check.sh [options]

Build a commit twice in clean, independent environments and compare the wasm
SHA-256 hashes.

Options:
  --ref <ref>            Git ref to build. Default: HEAD
  --image <name>         Builder image tag. Default: accesslayer-wasm-builder:local
  --package <name>       Cargo package to build. Default: creator-keys
  --local                Build locally with the pinned toolchain (no Docker).
  --skip-image-build     Reuse an existing builder image.
  -h, --help             Show this help.

Exit codes: 0 hashes match, 3 build failure, 5 hashes differ.
EOF
}

need_value() {
  if [ "$#" -lt 2 ]; then
    usage >&2
    echo "error: $1 requires a value" >&2
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
    --image)
      need_value "$@"
      IMAGE="$2"
      shift 2
      ;;
    --package)
      need_value "$@"
      PACKAGE="$2"
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
      usage >&2
      echo "error: unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [ "$LOCAL_BUILD" -eq 0 ] && ! command -v "$DOCKER" >/dev/null 2>&1; then
  echo "error: docker is required for a container build (or pass --local)" >&2
  exit 7
fi

COMMIT="$(git -C "$REPO_ROOT" rev-parse --verify "${REF}^{commit}" 2>/dev/null)" || {
  echo "error: git ref not found: $REF" >&2
  exit 2
}

WORK_DIR="$(mktemp -d)"
cleanup() {
  # shellcheck disable=SC2317
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [ "$LOCAL_BUILD" -eq 0 ] && [ "$BUILD_IMAGE" -eq 1 ]; then
  "$DOCKER" build --file "$REPO_ROOT/Dockerfile.release" --tag "$IMAGE" "$REPO_ROOT" >&2
  BUILD_IMAGE=0
fi

COMMON_ARGS=(--ref "$REF" --package "$PACKAGE" --image "$IMAGE")
if [ "$LOCAL_BUILD" -eq 1 ]; then
  COMMON_ARGS+=(--local)
fi
if [ "$BUILD_IMAGE" -eq 0 ]; then
  COMMON_ARGS+=(--skip-image-build)
fi

ARTIFACT_NAME="$(printf '%s' "$PACKAGE" | tr '-' '_').wasm"

echo "Build #1 of $REF ($COMMIT)"
if ! "$REPO_ROOT/scripts/build-wasm.sh" "${COMMON_ARGS[@]}" --out-dir "$WORK_DIR/build-1"; then
  echo "error: build #1 failed" >&2
  exit 3
fi

echo
echo "Build #2 of $REF ($COMMIT)"
if ! "$REPO_ROOT/scripts/build-wasm.sh" "${COMMON_ARGS[@]}" --out-dir "$WORK_DIR/build-2"; then
  echo "error: build #2 failed" >&2
  exit 3
fi

HASH1="$(sha256sum "$WORK_DIR/build-1/$ARTIFACT_NAME" | awk '{print $1}')"
HASH2="$(sha256sum "$WORK_DIR/build-2/$ARTIFACT_NAME" | awk '{print $1}')"

RESULT_DIR="$REPO_ROOT/target/reproducible-check"
mkdir -p "$RESULT_DIR"
cp "$WORK_DIR/build-1/$ARTIFACT_NAME" "$RESULT_DIR/build-1-$ARTIFACT_NAME"
cp "$WORK_DIR/build-2/$ARTIFACT_NAME" "$RESULT_DIR/build-2-$ARTIFACT_NAME"
{
  echo "ref: $REF"
  echo "commit: $COMMIT"
  echo "build_1_sha256: $HASH1"
  echo "build_2_sha256: $HASH2"
} > "$RESULT_DIR/hashes.txt"

echo
echo "----------------------------------------"
printf 'build #1 sha256: %s\n' "$HASH1"
printf 'build #2 sha256: %s\n' "$HASH2"
echo "----------------------------------------"

if [ "$HASH1" = "$HASH2" ]; then
  echo "REPRODUCIBLE: both clean builds produced identical wasm hashes."
  echo "Artifacts copied to $RESULT_DIR"
  exit 0
fi

echo "NOT REPRODUCIBLE: the two clean builds produced different hashes." >&2
echo "Artifacts copied to $RESULT_DIR" >&2
exit 5
