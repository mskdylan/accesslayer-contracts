# Reproducible release builder for the Access Layer Soroban contracts.
#
# Everything that can influence the wasm bytes is pinned here:
#
#   * Base image tag and digest pin Stellar CLI 25.2.0 and Rust 1.90.0, with
#     the wasm32v1-none target preinstalled. The image also sets
#     RUSTUP_TOOLCHAIN, so an in-source rust-toolchain.toml cannot silently
#     switch compilers inside the container.
#   * Cargo.lock pins every crate version and checksum; release builds pass
#     `--locked` so the lockfile can never be rewritten.
#   * The release profile in Cargo.toml (opt-level "z", LTO, one codegen unit,
#     panic abort, symbols stripped, no debug info) is committed to the repo.
#   * RUSTFLAGS rewrites machine-specific paths to a fixed virtual layout so
#     panics and other embedded path strings do not depend on where the source
#     or the Cargo cache lives. The image's CARGO_HOME is /stellar/.cargo and
#     rustup lives in /usr/local/rustup; both are remapped.
#   * SOURCE_DATE_EPOCH removes clock-based inputs from tools that honour it.
#
# The source tree is NOT baked into the image. scripts/build-release-wasm.sh
# exports an exact git commit, mounts it read-only at /source and collects the
# wasm and its SHA-256 sidecar from /out.
#
# The image runs as its non-root "stellar" user (inherited from the base), so
# the scripts make their output directories writable by the container user.
#
# Keep the tag/digest below in sync with releases.json (build.builderImage) and
# the Rust version in rust-toolchain.toml; scripts/generate-release-metadata.py
# validate enforces this in CI.

FROM stellar/stellar-cli:25.2.0-rust1.90.0-slim-bookworm@sha256:d568e243c18c306af45330d05276c4ebabce05a46c2197743a4fcadbbadab927

ENV CARGO_TERM_COLOR=never \
    CARGO_INCREMENTAL=0 \
    SOURCE_DATE_EPOCH=0 \
    TZ=UTC \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    RUSTFLAGS="--remap-path-prefix=/source=/build --remap-path-prefix=/stellar/.cargo=/cargo --remap-path-prefix=/usr/local/cargo=/cargo --remap-path-prefix=/usr/local/rustup=/rustup"

# COPY preserves the executable bit from git, and runs as the builder rather
# than the non-root runtime user, so no chmod step is needed.
COPY scripts/build-wasm-in-container.sh /usr/local/bin/build-wasm

WORKDIR /source

ENTRYPOINT ["/usr/local/bin/build-wasm"]
