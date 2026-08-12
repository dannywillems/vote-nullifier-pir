# Top-level Makefile — delegates to nf-server and subcrates
#
# Storage: flat binary files (no SQLite).
#
# Under PIR_DATA_DIR (default `pir-data/` at repo root when using Make):
#   nullifiers.bin         – append-only raw 32-byte nullifier blobs
#   nullifiers.dataset.json – nullifier pool + dataset version
#   nullifiers.checkpoint  – 16-byte (height LE, offset LE) crash-recovery marker
#   nullifiers.index       – height → byte offset index
#   nullifiers.tree        – versioned bincode PIR Merkle checkpoint
#   tier0/1.bin, pir_root.json – PIR tier payload + metadata
#
# Pipeline: `make sync` → `make serve`
# ──────────────────────────────────
# `make sync` runs `nf-server sync` (nullifiers from lightwalletd → tree checkpoint → tiers).
# Empty `SVOTE_PIR_VOTING_CONFIG_URL` skips voting height cap / prompts.
# `SVOTE_PIR_SYNC_RESET=1` wipes the dataset + tree + tiers before a run.
# `make sync-invalidate` passes `--invalidate-after-blocks` (rebuild tree + tiers when new blocks were synced).

ROOT        := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
NF_DIR      := nf-server
# Workspace builds emit binaries under the repo-root `target/`, not `nf-server/target/`.
NF_RELEASE_BIN := $(ROOT)/target/release/nf-server

# ── Configuration (override with env vars) ───────────────────────────
# Single on-disk root for nullifiers, tree checkpoint, and tier files (`SVOTE_PIR_DATA_DIR`).
PIR_DATA_DIR ?= pir-data
LWD_URL       ?= https://us.zec.stardust.rest:443
ZCASH_NETWORK ?= main
PORT          ?= 3000
SYNC_HEIGHT   ?=

# `make install`: DESTDIR for packaging. PREFIX defaults to ~/.local (no sudo); system-wide:
# `sudo make install PREFIX=/usr/local`. Cargo features: INSTALL_FEATURES (default serve).
PREFIX           ?= $(HOME)/.local
DESTDIR          ?=
INSTALL_FEATURES ?= serve

# Validate SYNC_HEIGHT and build --max-height for `nf-server sync`.
ifdef SYNC_HEIGHT
  ifneq ($(shell expr $(SYNC_HEIGHT) % 10),0)
    $(error SYNC_HEIGHT must be a multiple of 10, got $(SYNC_HEIGHT))
  endif
  _MAX_HEIGHT_FLAG := --max-height $(SYNC_HEIGHT)
else
  _MAX_HEIGHT_FLAG :=
endif

_SYNC_CMD := cd $(NF_DIR) && cargo run --release -- sync --zcash-network $(ZCASH_NETWORK) --pir-data-dir ../$(PIR_DATA_DIR) --lwd-url $(LWD_URL) $(_MAX_HEIGHT_FLAG)

# ── Tool versions (keep in sync with .github/workflows/) ─────────────
# Installed by `make setup-tools`; the targets that need them are not
# wired into CI yet, so a fresh clone can run everything else without
# installing anything.
CARGO_DENY_VERSION  ?= 0.20.2
CARGO_AUDIT_VERSION ?= 0.22.2
TAPLO_VERSION       ?= 0.10.0
CARGO_MSRV_VERSION  ?= 0.19.3
CARGO_HACK_VERSION  ?= 0.6.45

# ── Targets ──────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Build the nf-server binary (release)
	cargo build --locked -p nf-server --release

.PHONY: install
install: ## Install nf-server (INSTALL_FEATURES; PREFIX defaults to ~/.local, use sudo for /usr/local)
	cd $(ROOT) && cargo build -p nf-server --release --features "$(INSTALL_FEATURES)"
	mkdir -p "$(DESTDIR)$(PREFIX)/bin"
	install -m 0755 "$(NF_RELEASE_BIN)" "$(DESTDIR)$(PREFIX)/bin/nf-server"

.PHONY: sync
sync: ## `nf-server sync`: nullifiers + tree checkpoint + PIR tiers (resumable)
	$(_SYNC_CMD)

.PHONY: sync-invalidate
sync-invalidate: ## Same as sync with `--invalidate-after-blocks` (rebuild tree/tiers when new blocks synced)
	cd $(NF_DIR) && cargo run --release -- sync --zcash-network $(ZCASH_NETWORK) --pir-data-dir ../$(PIR_DATA_DIR) --lwd-url $(LWD_URL) --invalidate-after-blocks $(_MAX_HEIGHT_FLAG)

.PHONY: serve
serve: ## Start the PIR HTTP server
	cd $(NF_DIR) && cargo run --release --features serve -- serve --zcash-network $(ZCASH_NETWORK) --pir-data-dir ../$(PIR_DATA_DIR) --port $(PORT)

# ── Developer targets ────────────────────────────────────────────────
# `.github/workflows/test.yml` calls these, so local and CI run the
# exact same commands. Every invocation passes `--locked`: the
# committed Cargo.lock is authoritative and drift must fail loudly.

.PHONY: setup-tools
setup-tools: ## Install the pinned dev tooling
	cargo install --locked cargo-deny  --version $(CARGO_DENY_VERSION)
	cargo install --locked cargo-audit --version $(CARGO_AUDIT_VERSION)
	cargo install --locked taplo-cli   --version $(TAPLO_VERSION)
	cargo install --locked cargo-msrv  --version $(CARGO_MSRV_VERSION)
	cargo install --locked cargo-hack  --version $(CARGO_HACK_VERSION)

.PHONY: check
check: ## Type-check the whole workspace, all targets
	cargo check --workspace --all-targets --locked

.PHONY: check-format
check-format: check-format-rust check-format-toml ## Check Rust + TOML format

.PHONY: check-format-rust
check-format-rust: ## Check Rust formatting (stable rustfmt, as CI does)
	cargo fmt --all -- --check

.PHONY: check-format-toml
check-format-toml: ## Check TOML formatting (needs `make setup-tools`)
	taplo format --check

.PHONY: format
format: format-rust format-toml ## Format Rust + TOML

.PHONY: format-rust
format-rust: ## Format Rust sources
	cargo fmt --all

.PHONY: format-toml
format-toml: ## Format TOML files (needs `make setup-tools`)
	taplo format

.PHONY: lint
lint: ## Clippy over the workspace, warnings denied
	cargo clippy --workspace --all-targets --locked -- -D warnings

.PHONY: lint-shell
lint-shell: ## Shellcheck every committed shell script
	shellcheck scripts/*.sh

# nf-server is a binary crate; run its unit tests plus the bootstrap_e2e
# integration suite under the `serve` feature (the only build
# configuration in which the bootstrap and /metrics modules compile in).
.PHONY: test
test: ## THE test set. CI runs exactly this.
	cargo test --locked --lib -p imt-tree
	cargo test --locked --lib -p nf-ingest
	cargo test --locked -p pir-types -p pir-export -p pir-client
	cargo test --locked -p nf-server --features serve

.PHONY: smoke
smoke: ## Binary smoke checks (doctor, release channels, serve --help)
	cargo run --locked -p nf-server -- doctor
	scripts/test_release_channel.sh
	cargo run --locked --quiet -p nf-server --features serve -- \
		serve --help | grep -Fq -- '--zcash-network'

.PHONY: test-release
test-release: ## The test set in release mode (debug_assert! compiled out)
	cargo test --locked --release --lib -p imt-tree
	cargo test --locked --release --lib -p nf-ingest
	cargo test --locked --release -p pir-types -p pir-export -p pir-client
	cargo test --locked --release -p nf-server --features serve

.PHONY: test-doc
test-doc: ## Doc tests for the published crates
	cargo test --locked --doc -p imt-tree -p pir-types -p pir-client

.PHONY: test-e2e
test-e2e: ## In-process end-to-end harness
	cargo run --locked --release -p pir-test -- small

.PHONY: doc
doc: ## Build rustdoc for the published crates, warnings denied
	RUSTDOCFLAGS="-D warnings" cargo doc --no-deps --locked \
		-p imt-tree -p pir-types -p pir-client

.PHONY: audit
audit: ## RustSec advisory scan (needs `make setup-tools`)
	cargo audit --deny warnings

.PHONY: deny
deny: ## Licenses, advisories, bans, sources (needs `make setup-tools`)
	cargo deny check

.PHONY: msrv
msrv: ## Verify the declared rust-version builds (needs rust-version)
	cargo msrv verify

.PHONY: features
features: ## Every feature combination must compile
	cargo hack --workspace --feature-powerset --no-dev-deps check --locked

.PHONY: bench-check
bench-check: ## Benches must keep compiling
	cargo bench --locked -p imt-tree --no-run

.PHONY: ci
ci: check-format lint test smoke test-doc doc deny audit ## Full local gate

.PHONY: status
status: ## Show nullifier sync progress (count + checkpoint + tree file)
	@NF="$(PIR_DATA_DIR)/nullifiers.bin"; DATASET="$(PIR_DATA_DIR)/nullifiers.dataset.json"; CP="$(PIR_DATA_DIR)/nullifiers.checkpoint"; \
	TREE="$(PIR_DATA_DIR)/nullifiers.tree"; \
	echo "PIR data directory: $(PIR_DATA_DIR)"; \
	if [ -f "$$NF" ]; then \
		SIZE=$$(ls -lh "$$NF" | awk '{print $$5}'); \
		BYTES=$$(wc -c < "$$NF" | tr -d ' '); \
		COUNT=$$((BYTES / 32)); \
		echo "  nullifiers.bin: $$COUNT nullifiers ($$SIZE)"; \
	else \
		echo "  nullifiers.bin: not found"; \
	fi; \
	if [ -f "$$DATASET" ]; then \
		echo "  dataset: $$(tr -d '\n' < "$$DATASET")"; \
	else \
		echo "  dataset: not found"; \
	fi; \
	if [ -f "$$CP" ]; then \
		HEIGHT=$$(od -An -t u8 -j 0 -N 8 "$$CP" | tr -d ' '); \
		OFFSET=$$(od -An -t u8 -j 8 -N 8 "$$CP" | tr -d ' '); \
		echo "  checkpoint: height=$$HEIGHT offset=$$OFFSET"; \
	else \
		echo "  checkpoint: none"; \
	fi; \
	if [ -f "$$TREE" ]; then \
		TSIZE=$$(ls -lh "$$TREE" | awk '{print $$5}'); \
		echo "  nullifiers.tree: $$TSIZE (PIR tree checkpoint)"; \
	else \
		echo "  nullifiers.tree: not present"; \
	fi

.PHONY: clean
clean: ## Remove built artifacts and data files
	cargo clean
	rm -f $(PIR_DATA_DIR)/nullifiers.bin $(PIR_DATA_DIR)/nullifiers.dataset.json $(PIR_DATA_DIR)/nullifiers.dataset.json.tmp \
		$(PIR_DATA_DIR)/nullifiers.checkpoint $(PIR_DATA_DIR)/nullifiers.checkpoint.tmp $(PIR_DATA_DIR)/nullifiers.index \
		$(PIR_DATA_DIR)/nullifiers.tree $(PIR_DATA_DIR)/nullifiers.tree.tmp \
		$(PIR_DATA_DIR)/tier2.bin $(PIR_DATA_DIR)/tier2.precompute $(PIR_DATA_DIR)/tier2.precompute.tmp \
		$(PIR_DATA_DIR)/tier0.bin $(PIR_DATA_DIR)/tier1.bin $(PIR_DATA_DIR)/pir_root.json
