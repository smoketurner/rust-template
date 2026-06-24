# Architecture

How the pieces of a project built from this template fit together.

## Workspace

A virtual Cargo workspace (`Cargo.toml` has no `[package]`). All crates live under
`crates/` and are discovered by `members = ["crates/*"]`. Shared settings come from the
root:

- `[workspace.package]` — `version`, `edition = "2024"`, `rust-version` (MSRV), `license`.
  Inherit per crate with `edition.workspace = true`, etc.
- `[workspace.dependencies]` — the pinned dependency menu. Crates use
  `dep = { workspace = true, features = ["..."] }`.
- `[workspace.lints]` — the strict lint baseline. Crates use `[lints] workspace = true`.

`resolver = "3"` (the edition-2024 default) gives MSRV-aware dependency resolution.

## Recommended layering

```
            +-----------------------------+
            |        <name>-server        |  axum, rust-embed, fluent, Tailwind
            |        (or <name>-cli)      |  + persistence (db module):
            |                             |  sqlx + sea-query, migrations, DSQL auth
            +--------------+--------------+
                           | depends on
            +--------------v--------------+
            +-----------------------------+
```

- **`-common`** has no I/O. Pure types, the crate's error enum (`thiserror`), and config
  parsing. Everything else depends on it.
- **`-server`** owns the HTTP surface, the embedded UI, **and persistence**. Keep the data
  layer in a `db` module — the `Pool` abstraction over SQLite and Postgres/DSQL, the
  sea-query store, and migrations, exposing typed methods (never raw SQL) to handlers. The
  crate holds shared state (`Arc<AppState>` containing the store) and wires routes,
  middleware, assets, and i18n.

Keeping persistence in a `db` module and types in `-common` means the SQLite-vs-DSQL decision
and the sea-query translation never leak into request handlers.

## Request flow (server)

```
HTTP request
  -> tower middleware (request-id, timeout, body limit, i18n negotiation)
  -> axum handler
       -> store method (db module)      sea-query -> SqliteQueryBuilder | PostgresQueryBuilder
            -> sqlx Pool (Sqlite | Pg)  (Pg path wraps writes in OCC retry for DSQL)
       -> askama template + fluent translations
  -> response (HTML from embedded templates, assets from rust-embed)
```

## Lint inheritance

Every crate must declare:

```toml
[lints]
workspace = true
```

This applies the panic-prevention, cast, and arithmetic denies plus clippy `pedantic`
(as warnings) from the root. Without it, a crate silently escapes the baseline.

## Build & test flow

```bash
make check   # cargo check --workspace --all-targets --all-features
make lint    # clippy with -D warnings
make test    # cargo test --workspace --all-features
make deny    # cargo deny check (advisories, licenses, bans)
```

Tests use SQLite in-memory (`sqlite::memory:`) so they need no external services. The
Postgres/DSQL path is exercised against a real cluster or a vanilla Postgres for
wire-compatible checks; DSQL-only constraints are verified separately (`dsql.md`).

## Adding a layer

1. `cargo new --lib crates/<name>-<layer>` (see `crates/README.md`).
2. Add `[lints] workspace = true` and inherit package fields.
3. Pull deps from the workspace menu; add new ones (pinned) to `[workspace.dependencies]`.
4. Read the matching `docs/` file for that layer's patterns before writing code.
