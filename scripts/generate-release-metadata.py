#!/usr/bin/env python3
"""Generate and validate release metadata for reproducible contract builds.

`releases.json` is the committed record of the pinned build toolchain and every
released wasm hash. This script has two stdlib-only subcommands:

  validate   Check the build pins match the repository (rust-toolchain.toml,
             Dockerfile, Cargo.lock) and that recorded releases are well formed.
  generate   Hash the wasm built from a tag and write the release metadata file
             that the release workflow attaches to each GitHub release. With
             --update it also writes a releases.json copy containing the entry.

Output is deterministic: no timestamps or other volatile fields are written, so
generating metadata twice for the same inputs yields identical bytes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RELEASES = REPO_ROOT / "releases.json"
DOCKERFILE = REPO_ROOT / "Dockerfile"
TOOLCHAIN_FILE = REPO_ROOT / "rust-toolchain.toml"
CARGO_LOCK = REPO_ROOT / "Cargo.lock"

SCHEMA_VERSION = 1
TARGET = "wasm32v1-none"
PROFILE = "release"

IMAGE_RE = re.compile(
    r"^stellar/stellar-cli:"
    r"(?P<cli>\d+\.\d+\.\d+)"
    r"-rust(?P<rust>\d+\.\d+\.\d+)"
    r"-[A-Za-z0-9._-]+"
    r"@sha256:[0-9a-f]{64}$"
)
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
PACKAGE_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
TAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")

BUILD_KEYS = ("rust", "sorobanCli", "sorobanSdk", "builderImage")


class MetadataError(Exception):
    """A validation or generation problem that should be shown to the user."""


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise MetadataError(f"cannot read {path}: {exc}") from exc


def sha256_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
                size += len(chunk)
    except OSError as exc:
        raise MetadataError(f"cannot read {path}: {exc}") from exc
    return digest.hexdigest(), size


def toolchain_channel() -> str:
    text = read_text(TOOLCHAIN_FILE)
    channel = None
    try:
        import tomllib
    except ModuleNotFoundError:  # pragma: no cover - Python < 3.11
        match = re.search(r'^channel\s*=\s*"([^"]+)"', text, re.M)
        if match:
            channel = match.group(1)
    else:
        try:
            data = tomllib.loads(text)
        except tomllib.TOMLDecodeError as exc:
            raise MetadataError(f"{TOOLCHAIN_FILE}: invalid TOML: {exc}") from exc
        channel = data.get("toolchain", {}).get("channel")
    if not isinstance(channel, str) or not SEMVER_RE.match(channel):
        raise MetadataError(
            f"{TOOLCHAIN_FILE}: [toolchain].channel must be an exact version such as "
            f'"1.90.0" (found {channel!r}); floating channels are not reproducible'
        )
    return channel


def soroban_sdk_version() -> str:
    text = read_text(CARGO_LOCK)
    versions = set()
    for block in text.split("[[package]]"):
        if re.search(r'^name = "soroban-sdk"$', block, re.M):
            match = re.search(r'^version = "([^"]+)"$', block, re.M)
            if match:
                versions.add(match.group(1))
    if not versions:
        raise MetadataError(f"{CARGO_LOCK}: soroban-sdk is not pinned")
    if len(versions) > 1:
        raise MetadataError(
            f"{CARGO_LOCK}: soroban-sdk resolves to multiple versions: {sorted(versions)}"
        )
    return versions.pop()


def repo_facts() -> dict[str, str]:
    """The toolchain pins that the repository currently declares."""
    dockerfile = read_text(DOCKERFILE)
    match = re.search(r"^FROM\s+(\S+)", dockerfile, re.M)
    if not match:
        raise MetadataError(f"{DOCKERFILE}: no FROM line found")
    image = match.group(1)
    image_match = IMAGE_RE.match(image)
    if not image_match:
        raise MetadataError(
            f"{DOCKERFILE}: FROM must pin stellar/stellar-cli:<cli>-rust<rust>-<variant>"
            f"@sha256:<digest>, found {image!r}"
        )
    return {
        "rust": image_match.group("rust"),
        "sorobanCli": image_match.group("cli"),
        "sorobanSdk": soroban_sdk_version(),
        "builderImage": image,
    }


def load_releases(path: Path) -> dict:
    text = read_text(path)
    try:
        document = json.loads(text)
    except json.JSONDecodeError as exc:
        raise MetadataError(f"{path}: invalid JSON: {exc}") from exc
    if not isinstance(document, dict):
        raise MetadataError(f"{path}: top level must be a JSON object")
    return document


def validate_build_object(build: object, label: str, errors: list[str]) -> None:
    if not isinstance(build, dict):
        errors.append(f"{label} must be an object")
        return
    for key in BUILD_KEYS:
        value = build.get(key)
        if not isinstance(value, str) or not value:
            errors.append(f"{label}.{key} must be a non-empty string")
    extra = sorted(set(build) - set(BUILD_KEYS))
    if extra:
        errors.append(f"{label} has unknown keys: {', '.join(extra)}")
    rust = build.get("rust")
    cli = build.get("sorobanCli")
    if isinstance(rust, str) and not SEMVER_RE.match(rust):
        errors.append(f"{label}.rust must be an exact version, found {rust!r}")
    if isinstance(cli, str) and not SEMVER_RE.match(cli):
        errors.append(f"{label}.sorobanCli must be an exact version, found {cli!r}")
    image = build.get("builderImage")
    if isinstance(image, str):
        image_match = IMAGE_RE.match(image)
        if not image_match:
            errors.append(
                f"{label}.builderImage must be a digest-pinned "
                f"stellar/stellar-cli image, found {image!r}"
            )
        else:
            if rust != image_match.group("rust"):
                errors.append(
                    f"{label}.rust ({rust!r}) does not match the builder image "
                    f"({image_match.group('rust')!r})"
                )
            if cli != image_match.group("cli"):
                errors.append(
                    f"{label}.sorobanCli ({cli!r}) does not match the builder image "
                    f"({image_match.group('cli')!r})"
                )


def validate_contracts(contracts: object, label: str, errors: list[str]) -> None:
    if not isinstance(contracts, list) or not contracts:
        errors.append(f"{label} must be a non-empty list")
        return
    packages = set()
    for index, contract in enumerate(contracts):
        item = f"{label}[{index}]"
        if not isinstance(contract, dict):
            errors.append(f"{item} must be an object")
            continue
        package = contract.get("package")
        if not isinstance(package, str) or not PACKAGE_RE.match(package):
            errors.append(f"{item}.package must be a Cargo package name")
        elif package in packages:
            errors.append(f"{item}.package duplicates {package}")
        else:
            packages.add(package)
        wasm = contract.get("wasm")
        if (
            not isinstance(wasm, str)
            or not wasm.endswith(".wasm")
            or Path(wasm).name != wasm
        ):
            errors.append(f"{item}.wasm must be a bare .wasm file name")
        sha256 = contract.get("sha256")
        if not isinstance(sha256, str) or not SHA256_RE.match(sha256):
            errors.append(f"{item}.sha256 must be 64 lowercase hex characters")
        size = contract.get("bytes")
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
            errors.append(f"{item}.bytes must be a positive integer")


def validate_document(
    document: dict, path: Path, facts: dict[str, str], check_pins: bool = True
) -> list[str]:
    errors: list[str] = []

    if document.get("schemaVersion") != SCHEMA_VERSION:
        errors.append(
            f"schemaVersion must be {SCHEMA_VERSION}, found "
            f"{document.get('schemaVersion')!r}"
        )

    build = document.get("build")
    validate_build_object(build, "build", errors)
    if check_pins and isinstance(build, dict) and not errors:
        for key in BUILD_KEYS:
            if build.get(key) != facts[key]:
                errors.append(
                    f"build.{key} is {build.get(key)!r} but the repository pins "
                    f"{facts[key]!r}; update releases.json when bumping the toolchain"
                )

    releases = document.get("releases")
    if not isinstance(releases, list):
        errors.append("releases must be a list")
        releases = []

    seen_tags = set()
    for index, release in enumerate(releases):
        label = f"releases[{index}]"
        if not isinstance(release, dict):
            errors.append(f"{label} must be an object")
            continue
        tag = release.get("tag")
        if not isinstance(tag, str) or not TAG_RE.match(tag):
            errors.append(f"{label}.tag must be a release tag such as v0.1.0")
        elif tag in seen_tags:
            errors.append(f"{label}.tag duplicates {tag}")
        else:
            seen_tags.add(tag)
        commit = release.get("commit")
        if not isinstance(commit, str) or not COMMIT_RE.match(commit):
            errors.append(f"{label}.commit must be a full lowercase 40-hex SHA")
        validate_contracts(release.get("contracts"), f"{label}.contracts", errors)
        validate_build_object(release.get("build"), f"{label}.build", errors)

    unknown = sorted(set(document) - {"schemaVersion", "build", "releases"})
    if unknown:
        errors.append(f"unknown top-level keys: {', '.join(unknown)}")

    return errors


def check_document(
    document: dict, path: Path, facts: dict[str, str], check_pins: bool = True
) -> int:
    errors = validate_document(document, path, facts, check_pins)
    if errors:
        raise MetadataError(
            f"{path} is invalid:\n" + "\n".join(f"  - {error}" for error in errors)
        )
    return len(document["releases"])


def parse_wasm_specs(specs: list[str]) -> list[dict]:
    contracts = []
    packages = set()
    for spec in specs:
        if "=" not in spec:
            raise MetadataError(f"--wasm expects PACKAGE=PATH, found {spec!r}")
        package, raw_path = spec.split("=", 1)
        if not PACKAGE_RE.match(package):
            raise MetadataError(f"--wasm package is not a Cargo package name: {package!r}")
        if package in packages:
            raise MetadataError(f"--wasm package given twice: {package}")
        packages.add(package)
        path = Path(raw_path).expanduser()
        if not path.is_absolute():
            path = Path.cwd() / path
        if not path.is_file():
            raise MetadataError(f"--wasm file not found: {path}")
        sha256, size = sha256_file(path)
        if size == 0:
            raise MetadataError(f"--wasm file is empty: {path}")
        contracts.append(
            {
                "package": package,
                "wasm": path.name,
                "sha256": sha256,
                "bytes": size,
            }
        )
    contracts.sort(key=lambda contract: contract["package"])
    return contracts


def write_json(path: Path, document: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    except OSError as exc:
        raise MetadataError(f"cannot write {path}: {exc}") from exc


def command_validate(args: argparse.Namespace) -> int:
    facts = repo_facts()
    document = load_releases(args.releases)
    # The repository's own ledger must match the currently pinned toolchain.
    # Archived ledger copies (for example the one attached to an older release)
    # keep the pins they shipped with, so they are only checked structurally.
    check_pins = args.check_pins or args.releases.resolve() == DEFAULT_RELEASES.resolve()
    count = check_document(document, args.releases, facts, check_pins)
    print(
        f"{args.releases}: OK ({count} release(s); "
        f"rust {facts['rust']}, stellar-cli {facts['sorobanCli']}, "
        f"soroban-sdk {facts['sorobanSdk']})"
    )
    return 0


def command_generate(args: argparse.Namespace) -> int:
    facts = repo_facts()
    document = load_releases(args.releases)
    check_document(document, args.releases, facts)
    if args.update and args.update.exists():
        # When updating an existing ledger copy (for example the one attached to
        # an earlier release), merge into that copy and enforce its records too.
        document = load_releases(args.update)
        check_document(document, args.update, facts)

    tag = args.tag
    if not TAG_RE.match(tag):
        raise MetadataError(f"--tag is not a valid release tag: {tag!r}")
    commit = args.commit.lower()
    if not COMMIT_RE.match(commit):
        raise MetadataError(
            f"--commit must be the full 40-character commit SHA, found {args.commit!r}"
        )

    contracts = parse_wasm_specs(args.wasm)
    build = {key: document["build"][key] for key in BUILD_KEYS}
    entry = {
        "tag": tag,
        "commit": commit,
        "contracts": contracts,
        "build": build,
    }

    for existing in document["releases"]:
        if existing.get("tag") == tag and existing != entry:
            raise MetadataError(
                f"release {tag} is already recorded in {args.releases} with different "
                f"metadata; releases are immutable. Use a new tag, or edit "
                f"{args.releases} deliberately if the earlier record was wrong."
            )

    metadata = {
        "schemaVersion": SCHEMA_VERSION,
        "tag": tag,
        "commit": commit,
        "target": TARGET,
        "profile": PROFILE,
        "contracts": contracts,
        "build": build,
    }
    write_json(args.out, metadata)
    print(f"wrote {args.out}")
    for contract in contracts:
        print(
            f"  {contract['package']}: {contract['sha256']} "
            f"({contract['bytes']} bytes, {contract['wasm']})"
        )

    if args.update:
        updated = json.loads(json.dumps(document))
        updated["releases"] = [
            release for release in updated["releases"] if release.get("tag") != tag
        ]
        updated["releases"].append(entry)
        check_document(updated, args.update, facts)
        write_json(args.update, updated)
        print(f"recorded {tag} in {args.update}")

    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate and validate reproducible release metadata.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser(
        "validate", help="validate releases.json and the repository toolchain pins"
    )
    validate.add_argument(
        "--releases", type=Path, default=DEFAULT_RELEASES, help="releases.json to read"
    )
    validate.add_argument(
        "--check-pins",
        action="store_true",
        help="also require the ledger's build pins to match this checkout "
        "(implied for the repository's own releases.json)",
    )
    validate.set_defaults(func=command_validate)

    generate = subparsers.add_parser(
        "generate", help="write the per-release metadata file for a built tag"
    )
    generate.add_argument("--tag", required=True, help="release tag, e.g. v0.1.0")
    generate.add_argument("--commit", required=True, help="full 40-character commit SHA")
    generate.add_argument(
        "--wasm",
        action="append",
        required=True,
        metavar="PACKAGE=PATH",
        help="built wasm for a package; repeat for multiple contracts",
    )
    generate.add_argument("--out", type=Path, required=True, help="metadata file to write")
    generate.add_argument(
        "--releases", type=Path, default=DEFAULT_RELEASES, help="releases.json to read"
    )
    generate.add_argument(
        "--update",
        type=Path,
        metavar="PATH",
        help="also write a releases.json copy that records this release",
    )
    generate.set_defaults(func=command_generate)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except MetadataError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
