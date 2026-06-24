# CLAUDE.md

Guidance for Claude Code and the `rust-agents` plugin when working in this repository.

## What this is

An opinionated **template repository** for Rust services. It ships configuration, lints,
CI, supply-chain policy, and documented patterns — but **no member crates**. The chosen
stack:

- **Workspace** of crates under `crates/` (edition 2024, resolver 3, MSRV 1.96)
- **SQLite** for local dev and in-memory tests; **Amazon Aurora DSQL** (Postgres-compatible)
  in production
- **sea-query** as the query-building translation layer between the two backends, over **sqlx**
- **aws-lc-rs** as the single crypto/TLS provider (never OpenSSL or `ring`)
- **axum** + **rust-embed** + **fluent** (via `i18n-embed`) + **Tailwind CSS** for the
  embedded server UI

## Repository layout

```
Cargo.toml            # virtual workspace: deps menu + strict lints + profiles
.clippy.toml          # clippy tuning (levels live in Cargo.toml)
.rustfmt.toml         # stable-only formatting
deny.toml             # advisories, license allow-list, OpenSSL/ring bans
rust-toolchain.toml   # pinned 1.96.0 + rustfmt + clippy
Makefile              # build / fmt / lint / test / deny / css / run
crates/               # YOUR crates go here (none shipped) — see crates/README.md
docs/                 # the stack patterns, with code
.claude/rules/        # branching, commits, continuous-improvement conventions
```

## Conventions

- **Lints are strict and inherited.** Every crate uses `[lints] workspace = true`. The
  baseline denies panics (`unwrap`/`expect`/`panic`/`todo`), panic-prone indexing/slicing,
  lossy casts, and `arithmetic_side_effects`, and warns on all of clippy `pedantic`. In
  tests, opt out narrowly: `#[expect(clippy::unwrap_used, reason = "...")]`.
- **Dependencies are pinned** to exact versions in `[workspace.dependencies]` with
  `default-features = false`. Crates opt into features explicitly. When adding a dependency,
  look up the current version and add it there, not in the member crate.
- **Errors:** `thiserror` for library crates, `anyhow` for binaries.
- **Logging:** `tracing` (`error!`/`warn!`/`info!`/`debug!`), never `println!`.
- **Date/time:** `jiff`, not `chrono` or `time`.
- **Database IDs:** UUID v7, client-generated (`uuid::Uuid::now_v7()`) — never v4.
- **Types:** newtypes over primitives, enums for state machines, `let...else` for early returns.
- **Commits:** Conventional Commits (`.claude/rules/commits-and-issues.md`). No AI/co-author
  trailers. Never push to `main` — branch and PR.

## Project rules

Enforceable invariants the compiler can't catch — read before implementing or reviewing a
data-layer, crypto, or dependency change:

- **`.claude/rules/code-standards.md`** — crypto (aws-lc-rs only), DSQL/data-layer schema
  rules, and workspace hygiene, as review-gate checklists linking to `docs/`.
- `.claude/rules/branching.md`, `.claude/rules/commits-and-issues.md`,
  `.claude/rules/continuous-improvement.md` — branch/commit/CI conventions for the
  `rust-agents` flow.

## Common commands

```bash
make build     # cargo build --release
make fmt       # cargo fmt --all
make lint      # cargo clippy --workspace --all-targets --all-features -- -D warnings
make test      # cargo test --workspace --all-features
make deny      # cargo deny check
make css-build # build + minify Tailwind for the server crate
make help      # list targets
```

> Until you add a crate under `crates/`, cargo commands report "no members" — expected.

## Where to read more

The data-layer, DSQL, migration, query, UI, and crypto patterns each have a doc under
`docs/` (see the table in `README.md`). Read the relevant one before implementing that layer
— the DSQL constraints in particular (`docs/dsql.md`) change how schema and migrations must
be written versus vanilla Postgres.
