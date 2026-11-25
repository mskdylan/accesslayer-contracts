.PHONY: fmt fmt-check clippy test check ci wasm repro-wasm repro-check verify-deployment

## Code formatting targets
fmt:
	cargo fmt --all

fmt-check:
	cargo fmt --all -- --check

## Linting target
clippy:
	cargo clippy --workspace --all-targets -- -D warnings

## Test target
test:
	cargo test --workspace

## Basic compilation check
check:
	cargo check --workspace

## Refresh the committed WASM test fixture used by the upgrade tests.
##
## The fixture is checked in so the test suite compiles in CI without a WASM
## toolchain. That is what makes it go stale: after any change to the contract's
## code, re-run this and commit the refreshed fixture alongside the code change.
## The upgrade tests assert against the real build, so a stale fixture silently
## tests yesterday's contract.
WASM_TARGET := wasm32v1-none

wasm:
	rustup target add $(WASM_TARGET)
	cargo build --release --target $(WASM_TARGET) -p creator-keys
	mkdir -p creator-keys/test_wasm
	cp target/$(WASM_TARGET)/release/creator_keys.wasm creator-keys/test_wasm/contract.wasm
	@echo "Refreshed test fixture - commit it with your contract changes."
	@echo "Note: creator-keys-factory/test_wasm/ is NOT refreshed here. Despite living"
	@echo "under the factory, that fixture stands in for the creator-keys logic the"
	@echo "factory deploys, not the factory itself. The factory tests only assert on"
	@echo "registry addresses and never invoke the deployed contract, so a small"
	@echo "placeholder is sufficient there."

## Reproducible WASM builds and deployment verification
##
## Release builds run in the pinned Dockerfile.release environment. See
## docs/verification.md for the full third-party verification procedure.
RELEASE_REF ?= HEAD

repro-wasm:
	./scripts/build-wasm.sh --ref $(RELEASE_REF) --out-dir target/reproducible

repro-check:
	./scripts/repro-check.sh --ref $(RELEASE_REF)

verify-deployment:
	@test -n "$(CONTRACT_ID)" || { echo "usage: make verify-deployment CONTRACT_ID=C... RPC_URL=https://... RELEASE_REF=v1.0.0"; exit 2; }
	@test -n "$(RPC_URL)" || { echo "usage: make verify-deployment CONTRACT_ID=C... RPC_URL=https://... RELEASE_REF=v1.0.0"; exit 2; }
	./scripts/verify-deployment.sh --contract-id "$(CONTRACT_ID)" --rpc-url "$(RPC_URL)" --ref "$(RELEASE_REF)"

## Full CI workflow: runs format check, lint, tests, and compilation
## This is the standard check sequence to run before pushing to a branch
ci: fmt-check clippy test check
	@echo "✓ All CI checks passed"

## Convenience alias for running format checks and fixes
fmt-fix:
	cargo fmt --all

## Run all checks in sequence (alias for ci)
all-checks: ci

