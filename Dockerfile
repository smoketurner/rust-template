# syntax=docker/dockerfile:1
#
# Sample multi-stage Dockerfile: static musl binary in a distroless image.
#
# This template ships no crates yet, so this file will not build as-is. It
# assumes a server crate `app-server` (the Makefile's SERVER_CRATE default) and
# a shared `app-common` crate — rename both to your crates once they exist.
# Add COPY lines for any additional workspace members the build needs.
#
# Alpine's default Rust target is musl, so a plain `cargo build --release`
# produces a fully static binary that runs on the glibc-free distroless image.
# cargo-chef caches dependency compilation: only workspace crates recompile
# when your source changes.

# CSS build stage — download the standalone tailwindcss CLI and build the
# minified stylesheet that rust-embed bakes into the binary at compile time.
FROM debian:trixie-slim AS css-builder

# Declare TARGETARCH to receive automatic value from BuildKit
ARG TARGETARCH

WORKDIR /app

# Download standalone tailwindcss CLI with checksum verification.
# Checksums for v4.3.3:
#   tailwindcss-linux-x64:   dc61b3ac6b8c9ca874c0cc4c57b2409791a64c5540404ca5f5367360babc313a
#   tailwindcss-linux-arm64: 55fd0b241214eff3de1e8ee4f22796662f2d2e7a49bcfca7477cfd0bac398195
RUN apt-get update && apt-get install -y curl \
    && rm -rf /var/lib/apt/lists/* \
    && case "$TARGETARCH" in \
         amd64) \
           BINARY="tailwindcss-linux-x64" \
           CHECKSUM="dc61b3ac6b8c9ca874c0cc4c57b2409791a64c5540404ca5f5367360babc313a" \
           ;; \
         arm64) \
           BINARY="tailwindcss-linux-arm64" \
           CHECKSUM="55fd0b241214eff3de1e8ee4f22796662f2d2e7a49bcfca7477cfd0bac398195" \
           ;; \
         *) \
           echo "Unsupported architecture: $TARGETARCH" && exit 1 \
           ;; \
       esac \
    && curl -sLO "https://github.com/tailwindlabs/tailwindcss/releases/download/v4.3.3/${BINARY}" \
    && echo "${CHECKSUM}  ${BINARY}" | sha256sum -c - \
    && chmod +x "${BINARY}" \
    && mv "${BINARY}" tailwindcss

# Copy the static assets and everything Tailwind scans for class names.
COPY crates/app-server/static crates/app-server/static
COPY crates/app-server/tailwind.config.js crates/app-server/
COPY crates/app-server/styles crates/app-server/styles
COPY crates/app-server/templates crates/app-server/templates
COPY crates/app-server/src crates/app-server/src

# Build minified CSS
RUN cd crates/app-server \
    && /app/tailwindcss -i styles/input.css -o static/css/output.css --minify

# cargo-chef base stage — shared between planner and builder.
# Keep this Rust version in sync with rust-toolchain.toml.
FROM rust:1.97.1-alpine AS chef
RUN cargo install cargo-chef --locked
WORKDIR /app

# Planner stage — compute the dependency recipe from workspace manifests.
FROM chef AS planner
COPY Cargo.toml Cargo.lock ./
COPY crates/app-common/Cargo.toml crates/app-common/
COPY crates/app-server/Cargo.toml crates/app-server/

# Create dummy source files so cargo metadata can resolve the workspace.
RUN mkdir -p crates/app-common/src && touch crates/app-common/src/lib.rs \
    && mkdir -p crates/app-server/src && touch crates/app-server/src/lib.rs crates/app-server/src/main.rs
RUN cargo chef prepare --recipe-path recipe.json

# Rust build stage — musl static build.
FROM chef AS builder

# Build argument for reproducible builds
ARG SOURCE_DATE_EPOCH=0

# Build dependencies to compile aws-lc-rs from source on musl:
#   cmake/make/clang — build system and C compiler + libclang for bindgen
#   linux-headers/musl-dev — musl target headers
#   perl — aws-lc's assembly generation
# No openssl: this stack uses aws-lc-rs exclusively (deny.toml bans openssl/ring).
RUN apk add --no-cache musl-dev pkgconfig cmake make perl clang linux-headers

# Cook dependencies (cached until Cargo.toml/Cargo.lock change).
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --locked --package app-server --recipe-path recipe.json

# Restore real manifests (cook leaves stubs with placeholder versions).
COPY Cargo.toml Cargo.lock ./
COPY crates/app-common/Cargo.toml crates/app-common/
COPY crates/app-server/Cargo.toml crates/app-server/

# Copy actual source code and compile-time assets.
COPY crates/app-common/src crates/app-common/src
COPY crates/app-server/src crates/app-server/src
COPY crates/app-server/migrations crates/app-server/migrations
COPY crates/app-server/templates crates/app-server/templates

# Copy built static assets (embedded at compile time via rust-embed).
COPY --from=css-builder /app/crates/app-server/static crates/app-server/static

# Touch entry-point files with a deterministic timestamp for reproducible builds.
RUN touch -d "@${SOURCE_DATE_EPOCH}" crates/app-common/src/lib.rs crates/app-server/src/main.rs

# Build the static release binary.
RUN cargo build --release --locked --package app-server

# Create an empty data directory marker to copy into the scratch-based runtime.
RUN mkdir -p /data && touch /data/.keep

# Runtime stage — minimal static distroless image (no glibc).
FROM gcr.io/distroless/static-debian13:nonroot

WORKDIR /

# Update to your repository once you rename the template.
LABEL org.opencontainers.image.source=https://github.com/smoketurner/rust-template

# Copy the binary (static assets are embedded via rust-embed).
COPY --from=builder /app/target/release/app-server /app-server

# Create the data directory with correct ownership for the nonroot user.
COPY --from=builder --chown=nonroot:nonroot /data /data

# Environment defaults (see .env.example for the full list).
ENV RUST_LOG=info
ENV BIND_ADDR=0.0.0.0:3000
ENV DATABASE_URL=sqlite:/data/app.db?mode=rwc

EXPOSE 3000

ENTRYPOINT ["/app-server"]
