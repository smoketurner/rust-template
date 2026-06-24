# Continuous Improvement

Project-specific instructions for the continuous improvement cycle.
This file is read by the `rust-ci-analyst` agent and the `/rust-agents:continuous-improvement` skill.
Customize the sections below as the project grows.

## Test Configuration

Run the server against an in-memory SQLite database (no external setup):

```bash
DATABASE_URL="sqlite::memory:" cargo run --bin <server-crate>
```

Against a local on-disk SQLite file:

```bash
DATABASE_URL="sqlite://.local/testing/data/dev.db?mode=rwc" cargo run --bin <server-crate>
```

Against Aurora DSQL (production-like; requires AWS credentials in the environment):

```bash
DATABASE_URL="postgres://admin@<cluster>.dsql.<region>.on.aws/postgres" \
  AWS_REGION="<region>" cargo run --bin <server-crate>
```

For debug output:

```bash
RUST_LOG=debug cargo run --bin <server-crate> 2>.local/testing/debug/session.log
```

## Project Subsystems

Workspace members are auto-detected from `Cargo.toml`. Track these logical subsystems in
`coverage-status.md` as crates are added:

- **data layer** — pool/backend selection, sea-query translation, migrations
- **DSQL integration** — IAM token generation and refresh, OCC retry, async indexes
- **web/UI** — axum routing, rust-embed assets, fluent i18n, Tailwind
- **crypto** — aws-lc-rs default provider installation

## Interfaces

- Web API: `cargo run --bin <server-crate>` then `curl http://localhost:<port>/...`
- Embedded UI: same server, browser at `http://localhost:<port>/`
- CLI (if added): `cargo run --bin <cli-crate> -- <args>`

## Critical Paths

Features prone to silent breakage — live-test before any PR that touches them:

- Database migrations on **both** SQLite and Postgres/DSQL (DDL-per-transaction rules differ)
- DSQL IAM auth token generation and the background refresh task
- sea-query backend selection (`SqliteQueryBuilder` vs `PostgresQueryBuilder`)
- OCC retry handling on SQLSTATE `40001` (`OC000`/`OC001`)
- aws-lc-rs default crypto provider installed exactly once at startup

The implementation rules behind these paths are the review gates in
[`code-standards.md`](code-standards.md); the full stack patterns are the `docs/` table in
[`README.md`](../../README.md). Read them before changing the code behind any path above.

## Environment Setup

- **SQLite**: no setup; file lives at `.local/testing/data/`
- **Aurora DSQL**: AWS credentials via env/profile/role; cluster endpoint + region;
  TLS is mandatory (rustls + aws-lc-rs)
- **Tailwind**: `tailwindcss` CLI on PATH for `make css-build`

## Reference Projects

- **smoketurner/devbox** — Rust — workspace/lints/CI, aws-lc-rs crypto, DSQL via sqlx
- **vouch-sh/vouch** — Rust — SQLite↔DSQL data layer, sea-query translation, axum +
  rust-embed + fluent + Tailwind embedded UI

## Testing Notes

- The template ships no crates; live testing applies once at least one crate exists.
- DSQL cannot be run locally — exercise the Postgres path against a real cluster or a
  vanilla Postgres for wire-compatible smoke tests, then verify DSQL-specific constraints
  (see `docs/dsql.md`) separately.
