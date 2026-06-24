# rust-template

An opinionated GitHub **template repository** for building Rust services. It ships the
configuration, supply-chain policy, CI, and Claude-agent conventions up front — plus
documented patterns for the stack below — so a new project starts with the boring,
load-bearing decisions already made.

> This template ships **no crates**. The patterns are documented (with code) under
> [`docs/`](docs/); you add real crates under [`crates/`](crates/). Until you do,
> `cargo build` reports "no members" — that is expected.

## The stack

| Concern | Choice | Why |
|---|---|---|
| Workspace | Cargo workspace, crates under `crates/` | Edition 2024, resolver 3 |
| Local / test DB | SQLite (`sqlite::memory:` for tests) | Zero-setup, fast |
| Production DB | Amazon Aurora DSQL (Postgres-compatible) | Serverless, scalable |
| Query layer | [`sea-query`](https://crates.io/crates/sea-query) | One query, both SQLite & Postgres backends |
| DB driver | [`sqlx`](https://crates.io/crates/sqlx) | Async, `tls-rustls-aws-lc-rs` |
| Crypto / TLS | [`aws-lc-rs`](https://crates.io/crates/aws-lc-rs) | Preferred over OpenSSL and `ring` |
| Web | [`axum`](https://crates.io/crates/axum) | Embedded server UI |
| Assets | [`rust-embed`](https://crates.io/crates/rust-embed) | Single self-contained binary |
| i18n | [`fluent`](https://crates.io/crates/fluent-bundle) via `i18n-embed` | Per-request locale negotiation |
| Styling | [Tailwind CSS](https://tailwindcss.com) | Built to `static/css/output.css`, embedded |

## What's in the box

- **`Cargo.toml`** — virtual workspace with a curated, version-pinned `[workspace.dependencies]`
  menu and a strict `[workspace.lints]` baseline (clippy `pedantic` + panic/arithmetic/cast
  denies). Member crates inherit with `[lints] workspace = true`.
- **`.rustfmt.toml`, `.clippy.toml`, `deny.toml`, `rust-toolchain.toml`, `.editorconfig`** —
  formatting, lint tuning, supply-chain policy (advisories, licenses, bans — OpenSSL/`ring`
  denied), and a pinned toolchain.
- **`.github/`** — CI (fmt, clippy, `cargo test`, dependency-review, `cargo-deny`; actions
  SHA-pinned, plus `secure_workflows.yml` enforcing SHA pins) and Dependabot (cargo +
  actions, grouped, 7-day cooldown).
- **`Makefile`** — `build`, `fmt`, `lint`, `test`, `deny`, `css-build`, `run`, `help`.
- **`CLAUDE.md` + `.claude/rules/`** — conventions for the `rust-agents` Claude Code plugin
  (branching, Conventional Commits, continuous improvement).
- **`docs/`** — the patterns, with copy-pasteable code (see below).
- **Repo hygiene** — `AGENTS.md` (agent pointer to `CLAUDE.md`), `CONTRIBUTING.md`,
  `SECURITY.md`, `.env.example`, `.gitattributes`.

## Using this template

1. Click **"Use this template"** on GitHub (or `gh repo create <name> --template smoketurner/rust-template`).
2. Rename: update `repository` / package names, `LICENSE-*` copyright, and the
   `SERVER_CRATE` default in the `Makefile`.
3. Add your first crate under `crates/` — see [`crates/README.md`](crates/README.md).
   Once one crate exists, CI and `cargo build` work.
4. Read the docs as you wire up each layer.

## Documentation

| Doc | Covers |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Workspace layout, recommended crate split, lint inheritance |
| [docs/database.md](docs/database.md) | SQLite ↔ DSQL pool, IAM auth, connection lifecycle |
| [docs/dsql.md](docs/dsql.md) | Aurora DSQL SQL constraints (the deep reference) |
| [docs/migrations.md](docs/migrations.md) | Dual migration dirs, DSQL-safe runner, async indexes |
| [docs/sea-query.md](docs/sea-query.md) | Backend-dispatch macros, `Iden` schema, OCC retry |
| [docs/web-ui.md](docs/web-ui.md) | axum + rust-embed + fluent + Tailwind |
| [docs/crypto.md](docs/crypto.md) | aws-lc-rs default provider, keeping `ring`/OpenSSL out |
| [docs/ci-cd.md](docs/ci-cd.md) | CI jobs, and the deferred Docker/build/scan/release patterns |

## License

Dual-licensed under either of [Apache-2.0](LICENSE-APACHE) or [MIT](LICENSE-MIT) at your
option.
