#!/usr/bin/env python3
"""Validate releases.json and its consistency with the pinned build inputs.

Checks performed:
  * top-level schema and required build fields
  * build pins match rust-toolchain.toml, Dockerfile.release, and Cargo.toml
  * every release entry has a tag, 40-hex commit, 64-hex wasm hash,
    tool versions, and an ISO-8601 UTC timestamp
  * tags are unique and hashes are not placeholders
  * optional contract ids are valid contract StrKeys

Usage:
  python3 scripts/validate-releases.py
  python3 scripts/validate-releases.py --file releases.json --repo-root .

Exit code 0 when valid, 1 when invalid.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
CONTRACT_ID = re.compile(r"^C[A-Z2-7]{55}$")
ISO_UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
REPO_URL = re.compile(r"^https://[^\s]+$")

BUILD_REQUIRED = (
    "package",
    "artifact",
    "target",
    "rust_toolchain",
    "soroban_sdk",
    "stellar_cli",
    "dockerfile",
    "docker_base_image",
)

RELEASE_REQUIRED = (
    "tag",
    "commit",
    "wasm_sha256",
    "package",
    "target",
    "rust_toolchain",
    "soroban_sdk",
    "stellar_cli",
    "released_at",
)

ZERO_HASH = "0" * 64


def read_pins(repo_root: Path) -> dict[str, str]:
    """Read the actual pinned versions from the build definitions."""
    pins: dict[str, str] = {}

    toolchain = repo_root / "rust-toolchain.toml"
    dockerfile = repo_root / "Dockerfile.release"
    cargo = repo_root / "Cargo.toml"

    for path in (toolchain, dockerfile, cargo):
        if not path.is_file():
            raise ValueError(f"missing required file: {path}")

    rust_match = re.search(
        r'^channel\s*=\s*"([^"]+)"', toolchain.read_text(encoding="utf-8"), re.MULTILINE
    )
    if not rust_match:
        raise ValueError("could not read [toolchain].channel from rust-toolchain.toml")
    pins["rust_toolchain"] = rust_match.group(1)

    cli_match = re.search(
        r"^ARG\s+STELLAR_CLI_VERSION=(\S+)",
        dockerfile.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if not cli_match:
        raise ValueError("could not read ARG STELLAR_CLI_VERSION from Dockerfile.release")
    pins["stellar_cli"] = cli_match.group(1)

    sdk_match = re.search(
        r'^soroban-sdk\s*=\s*"([^"\s]+)"',
        cargo.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if not sdk_match:
        raise ValueError("could not read soroban-sdk from Cargo.toml")
    pins["soroban_sdk"] = sdk_match.group(1).lstrip("^=~")

    return pins


def validate(data: Any, pins: dict[str, str]) -> list[str]:
    errors: list[str] = []

    if not isinstance(data, dict):
        return ["top-level value must be a JSON object"]

    if data.get("schema_version") != 1:
        errors.append("schema_version must be 1")

    repository = data.get("repository")
    if not isinstance(repository, str) or not REPO_URL.match(repository):
        errors.append("repository must be an https URL")

    build = data.get("build")
    if not isinstance(build, dict):
        errors.append("build must be an object")
        build = {}

    for key in BUILD_REQUIRED:
        value = build.get(key)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"build.{key} must be a non-empty string")

    if isinstance(build.get("rust_toolchain"), str) and build.get("rust_toolchain") != pins["rust_toolchain"]:
        errors.append(
            "build.rust_toolchain does not match rust-toolchain.toml "
            f"({pins['rust_toolchain']})"
        )
    if isinstance(build.get("stellar_cli"), str) and build.get("stellar_cli") != pins["stellar_cli"]:
        errors.append(
            "build.stellar_cli does not match Dockerfile.release "
            f"({pins['stellar_cli']})"
        )
    if isinstance(build.get("soroban_sdk"), str) and build.get("soroban_sdk") != pins["soroban_sdk"]:
        errors.append(
            "build.soroban_sdk does not match Cargo.toml "
            f"({pins['soroban_sdk']})"
        )

    package = build.get("package")
    artifact = build.get("artifact")
    if isinstance(package, str) and isinstance(artifact, str):
        expected_artifact = package.replace("-", "_") + ".wasm"
        if artifact != expected_artifact:
            errors.append(f"build.artifact must be {expected_artifact} for package {package}")

    if isinstance(build.get("target"), str) and build.get("target") != "wasm32v1-none":
        errors.append("build.target must be wasm32v1-none for Soroban contracts")

    releases = data.get("releases")
    if not isinstance(releases, list):
        errors.append("releases must be an array")
        return errors

    seen_tags: set[str] = set()
    for index, entry in enumerate(releases):
        label = f"releases[{index}]"
        if not isinstance(entry, dict):
            errors.append(f"{label} must be an object")
            continue

        for key in RELEASE_REQUIRED:
            value = entry.get(key)
            if not isinstance(value, str) or not value.strip():
                errors.append(f"{label}.{key} must be a non-empty string")

        tag = entry.get("tag")
        if isinstance(tag, str) and tag:
            if tag in seen_tags:
                errors.append(f"{label}.tag duplicates an earlier release tag: {tag}")
            seen_tags.add(tag)

        commit = entry.get("commit")
        if isinstance(commit, str) and commit and not HEX40.match(commit):
            errors.append(f"{label}.commit must be a 40-character lowercase hex SHA")

        wasm_hash = entry.get("wasm_sha256")
        if isinstance(wasm_hash, str) and wasm_hash:
            if not HEX64.match(wasm_hash):
                errors.append(f"{label}.wasm_sha256 must be a 64-character lowercase hex SHA-256")
            elif wasm_hash == ZERO_HASH:
                errors.append(f"{label}.wasm_sha256 must not be a placeholder hash")

        released_at = entry.get("released_at")
        if isinstance(released_at, str) and released_at:
            if not ISO_UTC.match(released_at):
                errors.append(f"{label}.released_at must be an ISO-8601 UTC timestamp ending in Z")
            else:
                try:
                    datetime.strptime(released_at, "%Y-%m-%dT%H:%M:%SZ")
                except ValueError:
                    errors.append(f"{label}.released_at is not a valid timestamp")

        contracts = entry.get("contracts", [])
        if not isinstance(contracts, list):
            errors.append(f"{label}.contracts must be an array when present")
            contracts = []
        for c_index, contract in enumerate(contracts):
            c_label = f"{label}.contracts[{c_index}]"
            if not isinstance(contract, dict):
                errors.append(f"{c_label} must be an object")
                continue
            network = contract.get("network")
            contract_id = contract.get("contract_id")
            if not isinstance(network, str) or not network.strip():
                errors.append(f"{c_label}.network must be a non-empty string")
            if not isinstance(contract_id, str) or not CONTRACT_ID.match(contract_id):
                errors.append(f"{c_label}.contract_id must be a 56-character contract StrKey")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--file",
        default=None,
        help="releases.json to validate (default: <repo-root>/releases.json)",
    )
    parser.add_argument(
        "--repo-root",
        default=None,
        help="Repository root used to read pinned build inputs (default: script parent)",
    )
    args = parser.parse_args()

    repo_root = (
        Path(args.repo_root).resolve()
        if args.repo_root
        else Path(__file__).resolve().parent.parent
    )
    releases_file = Path(args.file).resolve() if args.file else repo_root / "releases.json"

    try:
        pins = read_pins(repo_root)
    except (OSError, ValueError) as error:
        print(f"releases.json: FAIL: {error}", file=sys.stderr)
        return 1

    try:
        data = json.loads(releases_file.read_text(encoding="utf-8"))
    except OSError as error:
        print(f"releases.json: FAIL: cannot read {releases_file}: {error}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as error:
        print(f"releases.json: FAIL: invalid JSON: {error}", file=sys.stderr)
        return 1

    errors = validate(data, pins)
    if errors:
        print(f"releases.json: FAIL ({releases_file})", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    releases = data.get("releases", [])
    print(
        f"releases.json: OK ({len(releases)} release(s); "
        f"Rust {pins['rust_toolchain']}, Stellar CLI {pins['stellar_cli']}, "
        f"Soroban SDK {pins['soroban_sdk']})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
