# Makefile for rust-template.
#
# NOTE: this template ships no crates yet, so cargo targets report
# "no members" until you add one under crates/ (see crates/README.md).

-include .env
export

CARGO ?= cargo

# Name of the server crate used by the CSS targets. Override once you create it:
#   make css-build SERVER_CRATE=my-server
SERVER_CRATE ?= app-server

.PHONY: all build check fmt fmt-check lint test test-coverage test-mutants deny css-dev css-build run help

all: build

##@ Build

build: ## Build the workspace (release)
	$(CARGO) build --release

check: ## Type-check the workspace
	$(CARGO) check --workspace --all-targets --all-features

##@ Quality

fmt: ## Format all code
	$(CARGO) fmt --all

fmt-check: ## Verify formatting without writing
	$(CARGO) fmt --all --check

lint: ## Run clippy with warnings denied
	$(CARGO) clippy --workspace --all-targets --all-features -- -D warnings

test: ## Run unit tests
	$(CARGO) test --workspace --all-features

test-coverage: ## Generate an HTML coverage report (requires cargo-llvm-cov)
	$(CARGO) llvm-cov --workspace --html

test-mutants: ## Run mutation testing (requires cargo-mutants)
	$(CARGO) mutants

deny: ## Check advisories, licenses, bans, and sources
	$(CARGO) deny check

##@ UI assets

css-dev: ## Watch and rebuild Tailwind CSS for the server crate
	cd crates/$(SERVER_CRATE) && tailwindcss -i styles/input.css -o static/css/output.css --watch

css-build: ## Build minified Tailwind CSS for the server crate
	cd crates/$(SERVER_CRATE) && tailwindcss -i styles/input.css -o static/css/output.css --minify

##@ Run

run: ## Run a binary: make run BIN=<name> ARGS="..."
	$(CARGO) run --bin $(BIN) -- $(ARGS)

##@ Help

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
