# Code Standards — review gates

Non-negotiable invariants for this stack that the compiler does **not** catch. Read this
before implementing or reviewing a change. Each item links to the doc with the full rationale
and code — this file is the gate, the doc is the detail.

> The `rust-agents` plugin does **not** auto-load this file. Its agents read
> `commits-and-issues.md`, `branching.md`, and `continuous-improvement.md` — each of which
> points here — and the main session reaches it through `CLAUDE.md`. Keep those pointers
> intact so the gates below reach plugin-spawned agents doing data-layer, crypto, or
> dependency work.

## Crypto & TLS → [docs/crypto.md](../../docs/crypto.md)

- [ ] **aws-lc-rs is the only crypto provider.** No `openssl`, `openssl-sys`, `native-tls`,
      or `ring` features on any dependency (`deny.toml` bans them).
- [ ] TLS crates use their rustls **+ aws-lc-rs** features (`rustls` → `aws_lc_rs`,
      `sqlx` → `tls-rustls-aws-lc-rs`, etc.).
- [ ] Binaries install the default provider **once** at the top of `main`
      (`aws_lc_rs::default_provider().install_default()`), before any TLS use.
- [ ] After touching TLS deps: `cargo tree -i ring` and `cargo tree -i openssl-sys` return no
      match; `cargo deny check` passes.

## Data layer & DSQL → [docs/dsql.md](../../docs/dsql.md), [docs/migrations.md](../../docs/migrations.md)

- [ ] **No `FOREIGN KEY`** in DDL — enforce referential integrity in code.
- [ ] **UUID v7 primary keys**, client-generated via `uuid::Uuid::now_v7()` — not v4
      (`gen_random_uuid()`), not `SERIAL`/sequential PKs.
- [ ] **One DDL statement per migration file**; never mix DDL and DML in one transaction.
- [ ] Indexes on non-empty tables use **`CREATE INDEX ASYNC`** (sync `CREATE INDEX` only on
      empty tables).
- [ ] Every write is **idempotent and wrapped in OCC retry** (`with_dsql_retry!`, SQLSTATE
      `40001`).
- [ ] Bulk writes chunked under the per-transaction row/byte limits; pool `max_lifetime` is
      **below the ~60-min** connection cap.
- [ ] No unsupported features: triggers, materialized views, PL/pgSQL, extensions, temp
      tables, `TRUNCATE`, `money`/`enum`/custom types.
- [ ] Queries built with sea-query through the `db_*!` dispatch macros — **no raw SQL in
      handlers**, and both backends covered.

## Workspace hygiene → [docs/architecture.md](../../docs/architecture.md)

- [ ] Every member crate declares `[lints] workspace = true` — no crate escapes the baseline.
- [ ] Dependencies are pinned `=x.y.z` with `default-features = false` in
      `[workspace.dependencies]`; members opt in with `{ workspace = true, features = [...] }`.
      New deps are added to the workspace menu (current version looked up), never inline.
- [ ] Panics opt out narrowly in tests only: `#[expect(clippy::unwrap_used, reason = "...")]`.
- [ ] `thiserror` for library crates, `anyhow` for binaries; `tracing` for logging, never
      `println!`/`eprintln!`.
- [ ] Date/time uses `jiff`, not `chrono` or `time`, for direct handling.

## Before opening a PR

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --locked --workspace
cargo deny check
```

(These require at least one crate under `crates/`.) See
[branching.md](branching.md) for the full pre-PR gate and
[commits-and-issues.md](commits-and-issues.md) for commit format.
