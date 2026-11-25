# Verifying a deployed contract

This guide lets an independent user, auditor, or integration partner confirm that
a deployed Access Layer contract was built from a published source commit, using
the pinned toolchain, without trusting the maintainers' local machine and without
any secret or account.

The verification question is:

> Does the wasm bytecode deployed at contract `C...` have the same SHA-256 hash
> as a clean build of tag `v...` from this repository, using the pinned
> `Dockerfile.release` environment?

If yes, the deployed code matches the reviewed source and build recipe (subject
to the limits in [Scope and limits](#scope-and-limits)).

## What is compared

Soroban identifies contract code by the SHA-256 hash of the wasm bytecode. That
hash is what a contract instance references on-chain. The verification script:

1. exports the requested git tag/commit into a clean tree with `git archive`,
2. builds `creator-keys` with `cargo build --release --locked` in the pinned
   builder image,
3. retrieves the deployed wasm code through the public Soroban RPC,
4. hashes both files with `sha256sum`, and
5. reports `MATCH` only when the two hashes are byte-for-byte identical.

The script also checks the wasm magic bytes (`\0asm`) so an RPC error page or
proxy response can never be mistaken for contract code, and it cross-checks
`releases.json` when the requested ref is recorded there.

## Prerequisites

- `git`
- `docker` (Docker Engine, Docker Desktop, or a compatible runtime)
- `sha256sum`, `od`, `jq`, `mktemp` (available in standard Linux/macOS shells)
- Network access to GitHub (source) and a public Soroban RPC endpoint

No Stellar account, secret key, funded identity, or API key is required. The
pinned builder image installs the Stellar CLI inside the container, so a local
`stellar` installation is not needed.

If Docker is unavailable, `--local` builds with the pinned
`rust-toolchain.toml` on your machine (Rust and `stellar` CLI then required).
A local build is useful for debugging, but it does **not** verify the pinned
container environment; prefer the Docker path for an official verification.

## 1. Identify the release and its source commit

Start from the GitHub release page for the tag (for example `v1.0.0`). Each
release has these assets:

| Asset | Purpose |
|---|---|
| `creator_keys.wasm` | The exact wasm built from the tag |
| `creator_keys.wasm.sha256` | SHA-256 of the attached wasm |
| `releases.json` | Verification metadata for all releases known at build time |
| `releases.json.sha256` | SHA-256 of the attached metadata file |

`releases.json` has this shape:

```json
{
  "schema_version": 1,
  "repository": "https://github.com/accesslayerorg/accesslayer-contracts",
  "build": {
    "package": "creator-keys",
    "artifact": "creator_keys.wasm",
    "target": "wasm32v1-none",
    "rust_toolchain": "1.89.0",
    "soroban_sdk": "22.0.11",
    "stellar_cli": "22.0.1",
    "dockerfile": "Dockerfile.release",
    "docker_base_image": "rust:1.89.0-bookworm",
    "cargo_command": "cargo build --release --locked --package creator-keys --target wasm32v1-none",
    "remap_path_prefixes": ["/source=/source", "/usr/local/cargo=/cargo", "/usr/local/rustup=/rustup"]
  },
  "releases": [
    {
      "tag": "v1.0.0",
      "commit": "0123456789abcdef0123456789abcdef01234567",
      "wasm_sha256": "abcdef...64 hex characters...",
      "package": "creator-keys",
      "target": "wasm32v1-none",
      "rust_toolchain": "1.89.0",
      "soroban_sdk": "22.0.11",
      "stellar_cli": "22.0.1",
      "released_at": "2026-01-01T00:00:00Z",
      "contracts": [
        { "network": "testnet", "contract_id": "C..." }
      ]
    }
  ]
}
```

Field rules enforced by `scripts/validate-releases.py`:

- `tag` is unique.
- `commit` is the full 40-character lowercase git SHA.
- `wasm_sha256` is the 64-character lowercase SHA-256 of the built wasm.
- `released_at` is an ISO-8601 UTC timestamp ending in `Z`.
- `build.rust_toolchain`, `build.stellar_cli`, and `build.soroban_sdk` must
  match `rust-toolchain.toml`, `Dockerfile.release`, and `Cargo.toml`.

The repository's `releases.json` documents the pinned build recipe and prior
releases. The copy attached to a specific GitHub release is authoritative for
that release because it is generated from the tagged build itself.

### Check the metadata file integrity

```bash
sha256sum -c releases.json.sha256   # after downloading both release assets
```

This detects download corruption. It does not by itself prove who produced the
file; see [Scope and limits](#scope-and-limits).

## 2. Obtain the pinned build environment

```bash
git clone https://github.com/accesslayerorg/accesslayer-contracts.git
cd accesslayer-contracts
git fetch --tags
git checkout v1.0.0
```

The build environment is defined by two committed files:

- `rust-toolchain.toml` pins Rust `1.89.0`, `rustfmt`, `clippy`, and the
  `wasm32v1-none` target.
- `Dockerfile.release` pins the base image `rust:1.89.0-bookworm` and Stellar
  CLI `22.0.1`, and installs the wasm target.

Build the builder image:

```bash
docker build --file Dockerfile.release --tag accesslayer-wasm-builder:local .
```

## 3. Build the contract from source

```bash
scripts/build-wasm.sh --ref v1.0.0 --out-dir target/reproducible
```

This exports the tag with `git archive` (uncommitted files are never included),
runs the build in the pinned container, and prints the wasm path and SHA-256:

```text
ref: v1.0.0 (<commit>)
wasm: /.../target/reproducible/creator_keys.wasm
sha256: <64 hex characters>
```

You can repeat the build with `scripts/repro-check.sh --ref v1.0.0`; it builds
the same commit twice in separate clean trees and fails if the hashes differ.

## 4. Compare with the release metadata (optional but recommended)

```bash
sha256sum target/reproducible/creator_keys.wasm
jq -r '.releases[] | select(.tag == "v1.0.0") | .wasm_sha256' releases.json
```

The two hashes must be identical. `scripts/verify-deployment.sh` performs this
cross-check automatically when the ref is recorded in `releases.json`.

## 5. Retrieve the deployed contract hash from a public RPC

The script uses the pinned Stellar CLI inside the builder image:

```bash
docker run --rm --entrypoint stellar \
  -v "$PWD/target/rpc:/out" \
  accesslayer-wasm-builder:local \
  contract fetch \
  --contract-id C... \
  --rpc-url https://soroban-testnet.stellar.org \
  --network-passphrase "Test SDF Network ; September 2015" \
  --out-file /out/deployed.wasm

sha256sum target/rpc/deployed.wasm
```

`stellar contract fetch` resolves the contract instance on-chain, reads its
`ContractCode` ledger entry, and writes the deployed bytecode. The SHA-256 of
that bytecode is the wasm hash the network associates with the contract.

Common public endpoints:

| Network | RPC URL | Passphrase |
|---|---|---|
| Testnet | `https://soroban-testnet.stellar.org` | `Test SDF Network ; September 2015` |
| Mainnet | `https://soroban.stellar.org` | `Public Global Stellar Network ; September 2015` |

Endpoints and availability are controlled by their operators; the script fails
clearly if the RPC is unreachable or returns something that is not wasm.

## 6. Run the verification script

```bash
scripts/verify-deployment.sh \
  --contract-id C... \
  --rpc-url https://soroban-testnet.stellar.org \
  --ref v1.0.0
```

Equivalent environment-variable form:

```bash
CONTRACT_ID=C... \
RPC_URL=https://soroban-testnet.stellar.org \
RELEASE_REF=v1.0.0 \
scripts/verify-deployment.sh
```

Mainnet requires the mainnet passphrase:

```bash
scripts/verify-deployment.sh \
  --contract-id C... \
  --rpc-url https://soroban.stellar.org \
  --ref v1.0.0 \
  --network-passphrase "Public Global Stellar Network ; September 2015"
```

Inputs are validated before anything runs: the contract ID must be a
56-character contract StrKey starting with `C`, and the RPC URL must be HTTP(S).
An invalid contract ID, unknown ref, or malformed flag exits with code 2. An RPC
that reports the contract does not exist exits with code 4.

## 7. Interpret the result

```text
RESULT: MATCH
The deployed contract wasm matches the build of v1.0.0 (<commit>).
```

Exit code `0`: the deployed wasm is byte-identical to a clean build of the tag
in the pinned environment. Verification succeeded.

```text
RESULT: MISMATCH
  local build: <hash> (v1.0.0 / <commit>)
  on-chain:    <hash> (C...)
```

Exit code `5`: the deployed contract does **not** match this source/build
recipe. Do not treat the deployment as verified. Possible causes include a
different commit, a modified build environment, or an unintended deployment.

Exit codes:

| Code | Meaning |
|---|---|
| `0` | `MATCH` — verification succeeded |
| `1` | Unexpected/internal failure |
| `2` | Invalid usage or input (contract ID, RPC URL, ref, flag) |
| `3` | Local build failed or produced no wasm |
| `4` | RPC retrieval failed or returned non-wasm data |
| `5` | `MISMATCH` — hashes differ |
| `6` | `releases.json` is inconsistent with the local build |
| `7` | A required command is missing |

The script never reports `MATCH` on a failed build, failed RPC call, empty
response, non-wasm response, or metadata inconsistency.

## 8. Verify release metadata authenticity and consistency

- Compare the `tag` and `commit` in the release asset's `releases.json` with the
  GitHub tag and its commit.
- Compare `wasm_sha256` with the local build and with
  `creator_keys.wasm.sha256`.
- Confirm `rust_toolchain`, `stellar_cli`, and `soroban_sdk` equal the pins in
  `rust-toolchain.toml`, `Dockerfile.release`, and `Cargo.toml` at that tag.
- Recompute the metadata checksum:
  `sha256sum -c releases.json.sha256`.

For an extra independent check, rebuild the tag twice:

```bash
scripts/repro-check.sh --ref v1.0.0
```

Both builds must print the same hash. The repository CI runs the same check on
every change to the build inputs by building the commit twice in fresh
containers; the workflow fails if the hashes differ.

## Scope and limits

- Verification proves the deployed bytecode matches this source and build
  recipe. It does not prove the source is free of bugs or that the contract
  admin is trustworthy.
- The pinned toolchain removes the most common reproducibility problems
  (compiler drift, floating dependencies, embedded local paths). It does not
  protect against a compromised build machine or a malicious pinned dependency
  revision; review `Cargo.lock` and the Docker base image tag as part of audit.
- The Stellar CLI and RPC endpoint are trusted to return the deployed contract
  code. Compare the locally computed hash with `releases.json` and, for
  high-assurance deployments, query more than one RPC provider.
- `releases.json` assets are not cryptographically signed. Authenticity currently
  rests on the GitHub release/tag being controlled by the expected repository
  owner. Treat its checksum as an integrity check, not a signature.

## Related files

- [`scripts/verify-deployment.sh`](../scripts/verify-deployment.sh)
- [`scripts/build-wasm.sh`](../scripts/build-wasm.sh)
- [`scripts/repro-check.sh`](../scripts/repro-check.sh)
- [`Dockerfile.release`](../Dockerfile.release)
- [`rust-toolchain.toml`](../rust-toolchain.toml)
- [`releases.json`](../releases.json)
- [`docs/deploy-artifacts.md`](./deploy-artifacts.md)
