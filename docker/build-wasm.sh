#!/usr/bin/env bash
#
# Build the release wasm inside the pinned builder image (or locally with the
# pinned rust-toolchain.toml toolchain).
#
# Inputs (environment):
#   SOURCE_DIR        Source tree to build (default /source)
#   OUT_DIR           Directory for the wasm and its .sha256 sidecar (default /out)
#   WASM_PACKAGE      Cargo package to build (default creator-keys)
#   WASM_TARGET       Rust target triple (default wasm32v1-none)
#   WASM_ARTIFACT     Artifact file name (default derived from the package)
#   CARGO_TARGET_DIR  Cargo target directory (default /tmp/cargo-target)
#
# The build is intentionally hermetic with respect to the workspace:
#   * --locked keeps the committed Cargo.lock
#   * CARGO_INCREMENTAL=0 and SOURCE_DATE_EPOCH=0 remove build-state drift
#   * RUSTFLAGS remap absolute source and toolchain paths so artifacts do not
#     embed the machine or checkout directory they were built in
#
# Run through scripts/build-wasm.sh rather than invoking this directly.

set -euo pipefail

PACKAGE="${WASM_PACKAGE:-creator-keys}"
TARGET="${WASM_TARGET:-wasm32v1-none}"
OUT_DIR="${OUT_DIR:-/out}"
SOURCE_DIR="${SOURCE_DIR:-/source}"
DEFAULT_ARTIFACT="$(printf '%s' "$PACKAGE" | tr '-' '_').wasm"
ARTIFACT_NAME="${WASM_ARTIFACT:-$DEFAULT_ARTIFACT}"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "error: source directory not found: $SOURCE_DIR" >&2
  exit 1
fi

cd "$SOURCE_DIR"

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/cargo-target}"
export CARGO_INCREMENTAL=0
export SOURCE_DATE_EPOCH=0
export TZ=UTC
export LC_ALL=C

echo "build: package=${PACKAGE} target=${TARGET} source=${SOURCE_DIR}" >&2
echo "build: rustc=$(rustc --version)" >&2
echo "build: cargo=$(cargo --version)" >&2

cargo build --release --locked --package "$PACKAGE" --target "$TARGET"

ARTIFACT="$CARGO_TARGET_DIR/$TARGET/release/$ARTIFACT_NAME"
if [ ! -f "$ARTIFACT" ]; then
  echo "error: expected wasm artifact not found: $ARTIFACT" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
cp "$ARTIFACT" "$OUT_DIR/$ARTIFACT_NAME"
(
  cd "$OUT_DIR"
  sha256sum "$ARTIFACT_NAME" | awk '{print $1}' > "$ARTIFACT_NAME.sha256"
)

echo "wasm: $OUT_DIR/$ARTIFACT_NAME" >&2
echo "sha256: $(cat "$OUT_DIR/$ARTIFACT_NAME.sha256")" >&2
