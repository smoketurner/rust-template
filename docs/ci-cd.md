# CI/CD

## What ships in the template

- **`.github/workflows/ci.yml`** — `fmt`, `clippy` (`--locked -D warnings`), `test`
  (`cargo test --locked`, Linux + macOS), `dependency-review` (PRs), and `license-check`
  (`cargo-deny check`). Toolchain from `rust-toolchain.toml` via `rustup show`; caching via
  `Swatinem/rust-cache`; actions SHA-pinned; `permissions: {}` top-level with per-job
  `contents: read`.
- **`.github/workflows/secure_workflows.yml`** — fails CI if any third-party action is used
  without a full commit-SHA pin (`zgosalvez/github-actions-ensure-sha-pinned-actions`).
- **`.github/dependabot.yml`** — `cargo` + `github-actions`, weekly, grouped, 7-day cooldown.

These cover everything a library/workspace needs. The pieces below produce and ship
**binaries/containers**, so they're documented here rather than scaffolded — add them once
you have a `-server`/`-cli` crate. They mirror what `smoketurner/devbox` and `vouch-sh/vouch`
do.

## Deferred: static musl binaries (`build` job)

Reproducible static binaries via `cargo-chef` (dependency caching) in `Dockerfile.build`,
orchestrated by `docker-bake.hcl`, invoked from a CI `build` matrix job.

`Dockerfile.build` (abridged):

```dockerfile
# syntax=docker/dockerfile:1
FROM rust:1.96.0-alpine AS base
RUN apk add --no-cache musl-dev pkgconfig cmake make clang linux-headers
RUN cargo install cargo-chef --locked

FROM base AS planner
WORKDIR /app
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM base AS builder
ARG TARGET
WORKDIR /app
RUN rustup target add "${TARGET}"
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --locked --target "${TARGET}" --recipe-path recipe.json
COPY . .
RUN cargo build --release --locked --target "${TARGET}" -p <name>-server

FROM scratch AS output
COPY --from=builder /app/target/${TARGET}/release/<name>-server /
```

`docker-bake.hcl` defines a `ci` target with `cache-from`/`cache-to` GitHub Actions cache.
The CI job:

```yaml
build:
  name: Build musl (${{ matrix.name }})
  runs-on: ${{ matrix.runner }}
  permissions:
    contents: read
  strategy:
    matrix:
      include:
        - { name: linux-arm64, runner: ubuntu-24.04-arm, target: aarch64-unknown-linux-musl }
  steps:
    - uses: actions/checkout@<sha> # pin
      with: { persist-credentials: false }
    - uses: docker/setup-buildx-action@<sha> # pin
    - uses: docker/bake-action@<sha> # pin
      with: { targets: ci }
      env: { TARGET: "${{ matrix.target }}" }
```

## Deferred: container vulnerability scan (`scan` job)

Build the server image (`Dockerfile`), scan it with Grype, and upload SARIF to the Security
tab. Runs on `push`:

```yaml
scan:
  if: github.event_name == 'push'
  permissions: { actions: read, contents: read, security-events: write }
  steps:
    - uses: actions/checkout@<sha>          # pin, persist-credentials: false
    - uses: docker/setup-buildx-action@<sha>
    - uses: docker/build-push-action@<sha>  # load: true, tags: <name>-server:scan
    - uses: anchore/scan-action@<sha>       # id: grype, severity-cutoff: high, output-format: sarif
    - uses: github/codeql-action/upload-sarif@<sha>
      with: { sarif_file: "${{ steps.grype.outputs.sarif }}" }
```

## Deferred: releases (`release.yml`)

On a `v*` tag: build the musl binaries (same bake `ci` target), assemble `dist/` with
crate-named assets, `sha256sum` them, and publish a GitHub release. The publish job needs
`permissions: contents: write` and uses `gh release create "$TAG" --generate-notes ./dist/*`.

## When you add these

1. Add `Dockerfile`, `Dockerfile.build`, `docker-bake.hcl`, `.dockerignore`.
2. Add the `cargo` `docker` ecosystem to `dependabot.yml`.
3. Pin every new action to a SHA (`secure_workflows.yml` enforces it) — resolve current SHAs
   with `gh api repos/<owner>/<repo>/commits/<tag> --jq .sha`.
4. Keep `--locked` on every cargo invocation and `persist-credentials: false` on checkout.
