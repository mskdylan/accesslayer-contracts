#!/usr/bin/env bash
#
# Build the release wasm for an exact git commit in the pinned builder image.
#
# The source tree is exported from git (`git archive`), so uncommitted changes
# can never leak into a release build, and the Dockerfile/helper script from the
# requested commit are used. Verifying an old tag therefore replays the build
# environment that tag shipped with.
#
# Usage: scripts/build-release-wasm.sh [options]
# See `--help` for the full option list.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/sha256.sh
. "$SCRIPT_DIR/lib/sha256.sh"

DEFAULT_IMAGE="accesslayer-wasm-builder:25.2.0-rust1.90.0"

REF="HEAD"
PACKAGE="creator-keys"
OUT_DIR="$REPO_ROOT/target/reproducible"
IMAGE="${BUILDER_IMAGE:-$DEFAULT_IMAGE}"
LOCAL_BUILD=0
BUILD_IMAGE=1
DOCKER="${DOCKER:-docker}"

usage() {
  cat <<'EOF'
Usage: scripts/build-release-wasm.sh [options]

Options:
  --ref <ref>          Git ref to build: tag, commit or branch. Default: HEAD.
  --package <name>     Cargo package to build. Default: creator-keys.
  --out-dir <dir>      Where to write the wasm and its .sha256 sidecar.
                       Default: target/reproducible.
  --image <name>       Builder image tag. Default: $BUILDER_IMAGE, or
                       accesslayer-wasm-builder:25.2.0-rust1.90.0.
  --local              Build with the pinned rust-toolchain.toml on this
                       machine instead of in the container. Not authoritative:
                       only the container build is byte-for-byte comparable
                       across machines.
  --skip-image-build   Reuse an existing builder image instead of rebuilding it
                       from the ref's Dockerfile.
  -h, --help           Show this help.

Environment:
  BUILDER_IMAGE        Default value for --image.
  DOCKER               Docker binary to use (default: docker).

Output (stdout):
  ref, commit, package, wasm path and sha256. Exit code 0 on success.
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
    --out-dir)
      need_value "$@"
      OUT_DIR="$2"
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
      die "unknown option: $1 (see --help)"
      ;;
  esac
done

case "$PACKAGE" in
  *[!a-z0-9-]* | "")
    die "invalid package name: $PACKAGE"
    ;;
esac

command -v git >/dev/null 2>&1 || die "git is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

COMMIT="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${REF}^{commit}")" ||
  die "git ref not found: $REF (try: git fetch --tags origin)"

ARTIFACT_NAME="$(printf '%s' "$PACKAGE" | tr '-' '_').wasm"

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
rm -f "$OUT_DIR/$ARTIFACT_NAME" "$OUT_DIR/$ARTIFACT_NAME.sha256"

if [ "$LOCAL_BUILD" -eq 1 ]; then
  command -v cargo >/dev/null 2>&1 || die "cargo is required for --local builds"
  echo "Building $PACKAGE at $COMMIT with the locally pinned toolchain" >&2
  CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"
  RUSTUP_HOME_DIR="${RUSTUP_HOME:-$HOME/.rustup}"
  (
    cd "$SOURCE_DIR"
    RUSTFLAGS="--remap-path-prefix=$SOURCE_DIR=/build --remap-path-prefix=$CARGO_HOME_DIR=/cargo --remap-path-prefix=$RUSTUP_HOME_DIR=/rustup" \
      CARGO_TARGET_DIR="$WORK_DIR/target" \
      CARGO_INCREMENTAL=0 \
      SOURCE_DATE_EPOCH=0 \
      cargo build --locked --release --target wasm32v1-none -p "$PACKAGE"
  )
  cp "$WORK_DIR/target/wasm32v1-none/release/$ARTIFACT_NAME" "$OUT_DIR/$ARTIFACT_NAME"
else
  command -v "$DOCKER" >/dev/null 2>&1 ||
    die "docker is required for a container build (or pass --local)"
  [ -f "$SOURCE_DIR/Dockerfile" ] ||
    die "no Dockerfile at $REF; container builds need the pinned builder definition"
  [ -f "$SOURCE_DIR/scripts/build-wasm-in-container.sh" ] ||
    die "no scripts/build-wasm-in-container.sh at $REF"

  if [ "$BUILD_IMAGE" -eq 1 ]; then
    "$DOCKER" build --file "$SOURCE_DIR/Dockerfile" --tag "$IMAGE" "$SOURCE_DIR" >&2
  else
    "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1 ||
      die "builder image $IMAGE not found; drop --skip-image-build or build it first"
  fi

  # The image runs as its non-root "stellar" user, which generally does not
  # share the host uid. The source is mounted read-only; the artifact directory
  # is made writable so the container can write the wasm and .sha256 sidecar.
  chmod 0777 "$OUT_DIR"

  # A fresh container per build: no shared target directory, no Cargo cache
  # volume, no inherited environment from the host.
  "$DOCKER" run --rm \
    --volume "$SOURCE_DIR:/source:ro" \
    --volume "$OUT_DIR:/out" \
    --env "WASM_PACKAGE=$PACKAGE" \
    "$IMAGE"
fi

ARTIFACT="$OUT_DIR/$ARTIFACT_NAME"
[ -s "$ARTIFACT" ] || die "build did not produce $ARTIFACT"

LOCAL_HASH="$(sha256_of_file "$ARTIFACT")"
if [ -f "$ARTIFACT.sha256" ]; then
  SIDECAR_HASH="$(awk '{print $1}' "$ARTIFACT.sha256")"
  [ "$SIDECAR_HASH" = "$LOCAL_HASH" ] ||
    die "sha256 sidecar ($SIDECAR_HASH) does not match the build output ($LOCAL_HASH)"
fi

cat <<EOF
ref: $REF
commit: $COMMIT
package: $PACKAGE
wasm: $ARTIFACT
sha256: $LOCAL_HASH
EOF
