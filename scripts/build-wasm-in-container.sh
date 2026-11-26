#!/bin/sh
#
# Build one package's release wasm inside the pinned builder image (Dockerfile).
#
# The repository is mounted read-only at /source and the artifact is written to
# /out, together with a .sha256 sidecar. This script is the container
# entrypoint; scripts/build-release-wasm.sh runs it for you.
#
# It uses POSIX sh because the base image does not guarantee bash.
#
# Environment:
#   WASM_PACKAGE  Cargo package to build (default: creator-keys)
#   OUT_DIR       Artifact directory (default: /out)
#
# Determinism inputs set by the image: CARGO_INCREMENTAL=0, SOURCE_DATE_EPOCH=0,
# TZ/LC_ALL fixed, and RUSTFLAGS with --remap-path-prefix. The build itself
# always passes --locked, --release and --target wasm32v1-none.

set -eu

PACKAGE="${WASM_PACKAGE:-creator-keys}"
OUT_DIR="${OUT_DIR:-/out}"
TARGET="wasm32v1-none"
PROFILE="release"
ARTIFACT_NAME="$(printf '%s' "$PACKAGE" | tr '-' '_').wasm"

if [ ! -f "Cargo.toml" ] || [ ! -f "Cargo.lock" ]; then
  echo "error: Cargo.toml/Cargo.lock not found in $PWD; mount the repository at /source" >&2
  exit 2
fi

case "$PACKAGE" in
  *[!a-z0-9-]* | "")
    echo "error: invalid package name: $PACKAGE" >&2
    exit 2
    ;;
esac

mkdir -p "$OUT_DIR"
# Keep the Cargo target directory outside the mounted source tree, which is
# intentionally read-only.
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/target}"
export CARGO_TARGET_DIR
export CARGO_INCREMENTAL=0

echo "rustc:   $(rustc --version)" >&2
echo "cargo:   $(cargo --version)" >&2
echo "stellar: $(stellar --version | sed -n '1p')" >&2
echo "package: $PACKAGE" >&2

cargo build --locked --release --target "$TARGET" -p "$PACKAGE"

ARTIFACT="$CARGO_TARGET_DIR/$TARGET/$PROFILE/$ARTIFACT_NAME"
if [ ! -s "$ARTIFACT" ]; then
  echo "error: expected artifact not found: $ARTIFACT" >&2
  exit 3
fi

cp "$ARTIFACT" "$OUT_DIR/$ARTIFACT_NAME"
(
  cd "$OUT_DIR"
  sha256sum "$ARTIFACT_NAME" >"$ARTIFACT_NAME.sha256"
)
cat "$OUT_DIR/$ARTIFACT_NAME.sha256"
