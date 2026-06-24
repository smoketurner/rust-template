# Amazon Aurora DSQL constraints

Aurora DSQL speaks the PostgreSQL 16 wire protocol but is a distributed, serverless engine
with **optimistic concurrency control** and a restricted SQL surface. Schema and migrations
must be written for DSQL, not vanilla Postgres. This is the reference; `migrations.md` and
`database.md` show the code.

> Quotas and the supported-SQL list change. Treat the numbers below as a design guide and
> confirm against the current AWS docs (links inline) before relying on a specific limit.

## What is not supported

| Feature | Status | What to do instead |
|---|---|---|
| `FOREIGN KEY` / `REFERENCES` | ✗ not enforced | Enforce referential integrity in application code |
| Triggers | ✗ | Move logic to the app |
| Stored procedures / PL/pgSQL | ✗ | `CREATE FUNCTION ... LANGUAGE SQL` only |
| Materialized views | ✗ | Regular views (✓, ≤ ~5,000) or app-side caching |
| Extensions (`CREATE EXTENSION`) | ✗ | No `uuid-ossp`; generate UUID v7 in app (`Uuid::now_v7()`) |
| Temporary tables | ✗ | CTEs / subqueries |
| `TRUNCATE` | ✗ | `DELETE FROM ...` |
| `money`, `enum`, range/geometric/custom types, hstore | ✗ | `numeric(19,2)`, `varchar` + `CHECK`, explicit columns, `jsonb` |
| Arrays as column types | ~ runtime only | Avoid array columns |

Supported and commonly used: `uuid`, `text`/`varchar`, integer/`numeric`/float types,
`boolean`, `bytea`, date/time/`timestamptz` (UTC), `jsonb` (≤ 1 MiB), and views.

Sources: [supported SQL features](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-postgresql-compatibility-supported-sql-features.html),
[supported data types](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-postgresql-compatibility-supported-data-types.html),
[migration guide](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-postgresql-compatibility-migration-guide.html).

## Primary keys: UUID v7, client-generated

Use **UUID v7** for every table id: generate it in the application with
`uuid::Uuid::now_v7()` and insert it explicitly (no server-side default). It works
identically on SQLite (`TEXT`) and DSQL (`uuid`), lets you know the id before the insert
(useful for idempotent retries), and is time-ordered so ids sort by creation with good index
locality.

Do **not** use `gen_random_uuid()` (that is UUID v4) or `SERIAL`/sequences. v4 discards the
time-ordering benefit; strictly sequential integer keys route every insert to one partition
and create a write hotspot. v7 carries a millisecond timestamp with a random tail, so writes
still spread within each time window.

Sequences and `GENERATED ... AS IDENTITY` exist but require an explicit cache of either `1`
or `≥ 65536` ([sequences](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/sequences-identity-columns.html)).
Reach for them only when you genuinely need monotonic ids.

## DDL rules

- **One DDL statement per transaction**, and **DDL cannot be mixed with DML** in the same
  transaction. Each migration file therefore holds exactly one DDL statement (or a set of
  DML statements in one transaction), never both.
- Schema changes bump a distributed catalog version. Sessions holding a stale version get
  **`40001` / `OC001`** ("schema updated by another transaction") and must retry.
- `ALTER TABLE` supports `ADD`/`DROP`/`RENAME COLUMN` and `RENAME`; you **cannot change the
  primary key** after creation — design it up front.

Source: [DDL and distributed transactions](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-ddl.html).

## Indexes are asynchronous

- `CREATE INDEX` (synchronous) only works on an **empty** table.
- For a table with rows, use `CREATE INDEX ASYNC`, which returns a `job_id` immediately and
  builds without locking. Wait for it before depending on the index:
  `SELECT * FROM sys.wait_for_job('<job_id>');`
- Index creation is async, so it lives outside the one-DDL-per-transaction rule.

Source: [asynchronous indexes](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-create-index-async.html).

## Optimistic concurrency control

DSQL takes no locks; it detects conflicts at commit and aborts the loser with **SQLSTATE
`40001`**:

- **`OC000`** — data conflict (two transactions wrote the same row).
- **`OC001`** — schema/catalog conflict (stale cached catalog).

Every write transaction must be **idempotent and retried** with backoff. See the
`with_dsql_retry!` pattern in `sea-query.md`.

Source: [concurrency control](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-concurrency-control.html).

## Transaction limits (verify current values)

A single transaction is bounded — roughly **3,000 rows modified**, **10 MiB of changes**,
and **5 minutes** — and a connection is dropped after about **60 minutes**. Bulk writes must
be chunked, and the pool's `max_lifetime` is set below the connection cap (see
`database.md`).

Source: [quotas and limits](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/CHAP_quotas.html).

## Connection & auth

- PostgreSQL **16** wire protocol, port **5432**, default database **`postgres`**, **TLS
  required** (rustls + aws-lc-rs).
- No password: connect with a short-lived **IAM auth token** (default ~15-minute validity)
  generated locally via SigV4 — no network round-trip. Admin vs non-admin roles use
  different token methods.

Sources: [accessing Aurora DSQL](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/accessing.html),
[authentication tokens](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/authentication-token.html).

## Design checklist

- [ ] UUID v7 primary keys, client-generated; no `gen_random_uuid()` (v4) or `SERIAL`
- [ ] No foreign keys in DDL; validate relationships in code
- [ ] One DDL statement per migration file; never DDL + DML together
- [ ] Indexes on non-empty tables via `CREATE INDEX ASYNC` + `sys.wait_for_job`
- [ ] All writes idempotent and wrapped in OCC retry
- [ ] Bulk writes chunked under the per-transaction row/byte limits
- [ ] Pool `max_lifetime` below the 60-minute connection cap; token refresh before expiry
- [ ] `numeric`/`varchar`+`CHECK`/`jsonb` instead of `money`/`enum`/custom types
