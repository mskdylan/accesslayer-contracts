# Reproducible builds and on-chain WASM verification

This guide explains how anyone can rebuild the exact wasm deployed for an
Access Layer contract from a release tag and compare it with the bytecode that
is actually on chain.

The process has no trusted middleman and needs no secrets: the build toolchain
is pinned in this repository, and reading a contract's wasm from a public
Soroban RPC endpoint is a read-only operation.

## What is pinned

| Input | Where it is pinned |
|-------|--------------------|
| Rust compiler | [`rust-toolchain.toml`](../rust-toolchain.toml) (`1.90.0`) |
| Stellar CLI + Rust + wasm target | [`Dockerfile`](../Dockerfile) base image `stellar/stellar-cli:25.2.0-rust1.90.0-slim-bookworm@sha256:d568e2…` |
| Crate versions | [`Cargo.lock`](../Cargo.lock), built with `--locked` |
| Build profile | `[profile.release]` in [`Cargo.toml`](../Cargo.toml) (opt-level `z`, LTO, 1 codegen unit, panic abort, stripped) |
| Target | `wasm32v1-none` |
| Build metadata record | [`releases.json`](../releases.json) (rust, stellar-cli, soroban-sdk, builder image) |

`scripts/generate-release-metadata.py validate` fails CI if `releases.json`
drifts from `rust-toolchain.toml`, the `Dockerfile` base image, or the
`soroban-sdk` version in `Cargo.lock`, so the recorded pins cannot silently go
stale.

Determinism measures applied by the pinned build:

- `cargo build --locked --release --target wasm32v1-none` — the lockfile is
  never rewritten.
- `--remap-path-prefix` rewrites the checkout location, `CARGO_HOME` and
  `RUSTUP_HOME` to fixed virtual paths (`/build`, `/cargo`, `/rustup`), so
  embedded path strings do not depend on where the build ran.
- `CARGO_INCREMENTAL=0`, `SOURCE_DATE_EPOCH=0`, `TZ=UTC`, `LC_ALL=C.UTF-8` —
  incremental state and clock/locale inputs are removed.
- The source comes from `git archive <commit>`, never from a dirty worktree.

## Prerequisites

To verify a deployment you need:

- **Docker** (Engine or Desktop). The pinned builder image is pulled
  automatically; it is ~350 MB, so the first run takes a while.
- **git**, including the release tags: `git fetch --tags origin`.
- **A Soroban RPC endpoint.** The Stellar CLI has public endpoints built in for
  `testnet`, `futurenet` and `mainnet`. No account, API key or funded identity
  is needed to read a contract's wasm.

Optional:

- A local Stellar CLI (`stellar`, v25.2.0 recommended) if you prefer to fetch
  the on-chain wasm yourself. `--stellar /path/to/stellar` makes the verifier
  use it. Otherwise it uses the CLI inside the pinned container.

This repository's history includes this Dockerfile from the commit that
introduced reproducible builds onward. Tags created before that do not contain
the pinned builder definition and cannot be rebuilt with this procedure.

## Reproduce a build

Build the wasm for a tag in the pinned container:

```bash
./scripts/build-release-wasm.sh --ref v0.1.0 --package creator-keys --out-dir dist
```

The script exports the commit with `git archive` (so uncommitted changes are
ignored), builds the image from the tag's own `Dockerfile`, runs a fresh
container, and prints:

```text
ref: v0.1.0
commit: 0123456789abcdef0123456789abcdef01234567
package: creator-keys
wasm: /path/to/dist/creator_keys.wasm
sha256: <hash>
```

Compute the hash yourself if you prefer:

```bash
sha256sum dist/creator_keys.wasm        # Linux
shasum -a 256 dist/creator_keys.wasm    # macOS
```

### Without Docker

```bash
./scripts/build-release-wasm.sh --ref v0.1.0 --local
```

`--local` uses the Rust version pinned by `rust-toolchain.toml` and the same
path remapping, but your OS, linker, CPU and installed components are not
pinned, so a local hash is only a hint, not proof. Always use the container
when a hash must be trusted.

### Verify that builds are reproducible

```bash
./scripts/repro-check.sh --ref v0.1.0
```

This builds the same commit twice in two separate clean containers and exits
non-zero if the two wasm hashes differ. The `reproducible-build` CI job runs the
same script for every pull request and push to `main`.

## Retrieve the deployed wasm hash

The wasm hash recorded on chain is the SHA-256 of the wasm bytes. Download the
deployed bytes through Soroban RPC and hash them:

```bash
stellar contract fetch \
  --id C... \
  --network testnet \
  --out-file /tmp/onchain.wasm
sha256sum /tmp/onchain.wasm
```

`stellar contract fetch` accepts `--rpc-url <url>` to use a specific RPC
provider. A public endpoint is enough; no key or secret is involved. Make sure
the network matches the network the contract was deployed to — a contract ID
that exists on testnet will not exist on mainnet. Stellar CLI 25.2.0 has no
`contract info hash` subcommand, and built-in asset contracts (SACs) have no
downloadable wasm, so use the contract ID of a deployed wasm contract.

You can also inspect how the CLI reached the ledger entry with
`stellar contract fetch --help` or by pointing it at your own RPC node.

## Verify a deployment

```bash
git fetch --tags origin

./scripts/verify-deployment.sh \
  --tag v0.1.0 \
  --contract-id C... \
  --network testnet
```

The verifier:

1. resolves `v0.1.0` to its commit,
2. builds that commit in the pinned container,
3. fetches the deployed wasm through the network's Soroban RPC endpoint,
4. compares both SHA-256 hashes.

Output ends with either:

```text
RESULT: MATCH
The deployed contract's wasm matches a reproducible build of v0.1.0.
```

or

```text
RESULT: MISMATCH
```

Exit codes:

| Code | Meaning |
|------|---------|
| `0` | MATCH — deployed bytecode equals the rebuilt bytecode |
| `1` | MISMATCH — bytecode differs |
| `2` | usage or infrastructure error (bad arguments, failed build, unreachable RPC, unknown tag) |

Useful options:

```bash
# Custom RPC provider / network alias
./scripts/verify-deployment.sh --tag v0.1.0 --contract-id C... \
  --network testnet --rpc-url https://my-rpc.example.com

# Verify a wasm you already built (skips the container build)
./scripts/verify-deployment.sh --tag v0.1.0 --contract-id C... \
  --wasm dist/creator_keys.wasm --stellar "$(command -v stellar)"

# Reuse an already-built builder image
./scripts/verify-deployment.sh --tag v0.1.0 --contract-id C... --skip-image-build
```

## Release metadata

[`releases.json`](../releases.json) is the committed ledger. It records:

- `build` — the current pinned Rust, Stellar CLI, soroban-sdk and builder image;
- `releases` — one entry per release, containing the tag, the full commit SHA,
  and for each contract its package, wasm file name, SHA-256 and size, plus the
  tool versions used for that release.

Generated metadata has no timestamps, so regenerating it for the same tag and
artifacts produces identical bytes. That is what makes it useful as an
independent record.

### Generate metadata for a release

```bash
./scripts/build-release-wasm.sh --ref v0.1.0 --out-dir dist

python3 scripts/generate-release-metadata.py generate \
  --tag v0.1.0 \
  --commit "$(git rev-parse v0.1.0^{commit})" \
  --wasm "creator-keys=dist/creator_keys.wasm" \
  --out dist/release-metadata.json
```

Add `--update dist/releases.json` to also produce a copy of the ledger with the
new release recorded. Validate any ledger with:

```bash
# Repository ledger: schema AND current toolchain pins are checked.
python3 scripts/generate-release-metadata.py validate

# An archived ledger copy (for example one attached to an older release):
# schema and per-release pins are checked, but not the current repository pins.
python3 scripts/generate-release-metadata.py validate --releases dist/releases.json

# Force the pin check for any path:
python3 scripts/generate-release-metadata.py validate --check-pins --releases releases.json
```

Validation checks the JSON schema, per-release build pins, hash formats,
duplicate tags/packages and (for the repository ledger) that the recorded
`build` object matches `rust-toolchain.toml`, the `Dockerfile` base image and
`Cargo.lock`. It rejects re-recording an existing tag with different bytes,
because release records are immutable. Archived ledgers are not compared with
today's pins, since a toolchain bump would otherwise make every historical
release look invalid.

### Release automation

[`.github/workflows/release.yml`](../.github/workflows/release.yml) runs on every
`v*` tag and:

1. validates `releases.json` against the repository pins,
2. builds the wasm in the pinned container,
3. generates `release-metadata.json` and an updated `releases.json`,
4. attaches `creator_keys.wasm`, its `.sha256` sidecar, `release-metadata.json`
   and `releases.json` to the GitHub release.

The updated `releases.json` is attached as a release asset. Commit it to the
default branch (or merge it from the release notes) so the ledger in git matches
what was published. The workflow does not push to protected branches on its own.

## Troubleshooting

### "tag not found" / hash does not reproduce an old release

Fetch tags and make sure you are using the canonical remote:

```bash
git fetch --tags origin
git rev-parse v0.1.0^{commit}
```

Tags created before the reproducible-build change do not contain the pinned
Dockerfile, so they cannot be rebuilt this way.

### MISMATCH but the commit is correct

Check, in order:

- **`Cargo.lock` changed after the release.** Any dependency edit changes the
  wasm. `git diff <tag> -- Cargo.lock` must be empty.
- **Different toolchain.** Rebuild in the container, not locally. The Rust
  version is part of the hash.
- **Post-processing.** `stellar contract optimize`, `wasm-opt`, or any manual
  re-upload changes the bytes. Verify against the exact artifact that was
  deployed.
- **Wrong contract ID or network.** Confirm the ID with the deployment record
  and that the network is the one the contract was deployed to.
- **Dirty worktree build.** The verifier always exports the commit, so local
  changes cannot leak in; but a wasm produced by hand from a dirty tree will not
  match.

### Docker permission errors or files owned by the container user

Add your user to the `docker` group (`sudo usermod -aG docker "$USER"`, then log
out and back in). The builder image runs as its non-root `stellar` user, which
may not share your host uid; the scripts make the output directory writable for
it. Build output is written under `dist/` or `target/`, which you can remove
with `rm -rf dist target/reproducible` (use `sudo` if your system still reports
a permission error).

### The RPC endpoint is unreachable or rate-limited

Public RPC endpoints are shared. Point the verifier at another provider with
`--rpc-url`, or run the fetch with `--stellar` against a local `stellar` CLI.
Read-only RPC access never requires credentials, so never paste keys into a
verification command.

### `wasm32v1-none` missing during a `--local` build

```bash
rustup target add wasm32v1-none
```

`rust-toolchain.toml` requests the target automatically for the pinned
toolchain, but an override (`RUSTUP_TOOLCHAIN`, `rustup default`) can bypass it.

### Verifying from an offline machine

The container build downloads crates from crates.io on first use and fetches the
on-chain wasm over the network. There is no vendored dependency bundle or
offline RPC, so both steps need network access. If you must verify offline,
mirror the crates and use a local Soroban RPC node, then pass `--rpc-url`.

## CI

- `Contracts CI` runs the existing format, clippy and test checks on the pinned
  Rust version, plus the `reproducible-build` job (`scripts/repro-check.sh`).
- `Release` produces and attaches the metadata for tagged commits.

## Test fixtures

`scripts/tests/run-tests.sh` covers the verification and metadata tooling
without Docker or a network: MATCH/MISMATCH/error exit codes are exercised with
a prebuilt wasm and a stub `stellar` CLI, and metadata generation is checked for
determinism, correct fields, ledger updates and toolchain-drift rejection.
