#!/usr/bin/env bash
#
# Portable SHA-256 helper sourced by the build/verification scripts.
# Linux ships `sha256sum`; macOS ships `shasum`. Both print the same hex digest.

# sha256_of_file <path> -> prints the lowercase hex digest
sha256_of_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo "error: cannot hash missing file: $path" >&2
    return 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    echo "error: need sha256sum (coreutils) or shasum to hash $path" >&2
    return 1
  fi
}
