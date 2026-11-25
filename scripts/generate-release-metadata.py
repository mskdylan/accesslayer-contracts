#!/usr/bin/env python3
"""Append a verified release entry to releases.json.

Used by .github/workflows/release.yml after the tagged commit has been built in
the pinned builder image. The wasm hash must come from that build; this script
never invents or derives a hash.

Usage:
  python3 scripts/generate-release-metadata.py \
    --releases-file releases.json \
    --output dist/releases.json \
    --tag v1.0.0 \
    --commit <40-hex sha> \
    --wasm-sha256 <64-hex sha256> \
    --rust-toolchain 1.89.0 \
    --soroban-sdk 22.0.11 \
    --stellar-cli 22.0.1 \
    --released-at 2026-01-01T00:00:00Z
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def normalize_timestamp(value: str) -> str:
    """Return an ISO-8601 UTC timestamp ending in Z."""
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--releases-file", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--wasm-sha256", required=True)
    parser.add_argument("--rust-toolchain", required=True)
    parser.add_argument("--soroban-sdk", required=True)
    parser.add_argument("--stellar-cli", required=True)
    parser.add_argument("--package", default="creator-keys")
    parser.add_argument("--target", default="wasm32v1-none")
    parser.add_argument("--released-at", required=True)
    args = parser.parse_args()

    source = Path(args.releases_file)
    data = json.loads(source.read_text(encoding="utf-8"))
    releases = data.setdefault("releases", [])
    if not isinstance(releases, list):
        print("error: releases must be an array", file=sys.stderr)
        return 1

    entry = {
        "tag": args.tag,
        "commit": args.commit,
        "wasm_sha256": args.wasm_sha256,
        "package": args.package,
        "target": args.target,
        "rust_toolchain": args.rust_toolchain,
        "soroban_sdk": args.soroban_sdk,
        "stellar_cli": args.stellar_cli,
        "released_at": normalize_timestamp(args.released_at),
    }

    # Re-running the workflow for a tag replaces that tag's entry instead of
    # producing duplicates.
    releases = [item for item in releases if item.get("tag") != args.tag]
    releases.append(entry)
    releases.sort(key=lambda item: (item.get("released_at", ""), item.get("tag", "")))
    data["releases"] = releases

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {output} with release {args.tag} ({args.commit})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
