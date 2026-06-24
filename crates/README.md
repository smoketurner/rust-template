# crates/

Your workspace members live here. The template ships **none** — you add them.

The root `Cargo.toml` picks up every crate via `members = ["crates/*"]`. Once one crate
exists, `cargo build`, CI, and the `Makefile` targets work.

## Recommended decomposition

This is guidance, not a requirement — split as the project needs:

| Crate | Responsibility | Key deps (from the workspace menu) |
|---|---|---|
| `<name>-common` | Shared domain types, error type (`thiserror`), config | `serde`, `thiserror`, `uuid`, `jiff` |
| `<name>-server` | axum server, embedded UI (rust-embed + fluent + Tailwind), and persistence: pool + backend selection, sea-query store, migrations, DSQL auth | `axum`, `rust-embed`, `askama`, `i18n-embed`, `tokio`, `anyhow`, `tracing`, `sqlx`, `sea-query`, `sea-query-sqlx`, `aws-sdk-dsql`, `aws-lc-rs` |
| `<name>-cli` | optional clap binary; shares `-common` | `clap`, `anyhow`, `rustls`, `aws-lc-rs` |

See `docs/architecture.md` for how the layers fit together, and the other `docs/` files for
each layer's patterns. Keep the data layer in a `db` module inside `-server` so the
SQLite-vs-DSQL split stays out of request handlers.

## Adding a crate

```bash
cargo new --lib crates/<name>-common    # or --bin for a binary
```

Then make it inherit the workspace baseline. A minimal member `Cargo.toml`:

```toml
[package]
name         = "<name>-common"
version.workspace      = true
edition.workspace      = true
rust-version.workspace = true
license.workspace      = true
publish      = false

[lints]
workspace = true

[dependencies]
serde     = { workspace = true, features = ["derive"] }
thiserror = { workspace = true }
```

Notes:

- Always include `[lints] workspace = true` so the strict lint baseline applies.
- Pull dependencies from the workspace menu with `{ workspace = true, features = [...] }`.
  If a crate you need isn't in `[workspace.dependencies]` yet, add it there (pinned, current
  version) rather than inline in the member.
- For binaries that open TLS connections, install the aws-lc-rs provider once at startup —
  see `docs/crypto.md`.
