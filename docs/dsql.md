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
| `money`, `enum`, range/geometric/custom types, hstore | ✗ | `numeric(19,4)`, `varchar` + inline `CHECK`, explicit columns, `jsonb` |
| Arrays as column types | ~ runtime only | Store as `jsonb`; expand with `jsonb_array_elements_text` |
| Table partitioning (`PARTITION BY`) | ✗ | Flat table — DSQL distributes via PK-ordered storage |
| Table inheritance (`INHERITS`) | ✗ | Merge inherited columns into each child table |
| Per-column `COLLATE` | ✗ | Database-wide C collation; `lower(col)` for case-insensitive |
| `UNLOGGED` tables | ✗ | All tables are durable; drop the keyword (cache in Redis/ElastiCache) |
| Storage params (`WITH (fillfactor …)`, autovacuum) | ✗ | DSQL manages storage; remove them — no `VACUUM` |
| `SECURITY DEFINER` functions | ✗ | Runs as caller; re-grant table access or enforce RLS in the app |

Supported and commonly used: `uuid`, `text`/`varchar`, integer/`numeric`/float types,
`boolean`, `bytea`, date/time/`timestamptz` (UTC), `jsonb` (≤ 1 MiB), views, `CREATE DOMAIN`,
and `GENERATED ALWAYS AS (expr) STORED` columns.

Sources: [supported SQL features](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-postgresql-compatibility-supported-sql-features.html),
[supported data types](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-postgresql-compatibility-supported-data-types.html),
[migration guide](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-postgresql-compatibility-migration-guide.html).

## Type and column rules

- **`NUMERIC` is capped at precision 38, scale 37.** Specify precision explicitly
  (`numeric(20,10)`); DSQL rejects unbounded `NUMERIC`.
- **C collation, database-wide.** Per-column `COLLATE` is rejected, and `ORDER BY` on text
  sorts by raw byte value (uppercase before lowercase, non-ASCII after `z`). Use `lower(col)`
  for case-insensitive ordering and comparison.
- **No array columns.** Store collections as `jsonb` and expand with
  `jsonb_array_elements_text(col)` at query time.
- **`enum` → `varchar` + inline `CHECK`, fixed at `CREATE TABLE`.** Adding or changing a
  `CHECK` later means recreating the table (`ALTER ... TYPE` / `DROP CONSTRAINT` are
  unsupported), so settle the allowed values up front.
- **Composite types** become a `jsonb` column (flexible) or separate columns (indexable).
- **At most 10 schemas per database.** Past 10, consolidate into `public` with table-name
  prefixes.

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

**Limits:** at most **24 indexes per table**, **8 columns per index**, and a **1 KiB**
key-size cap. Near the limit, prefer composite and `INCLUDE` indexes over many single-column
ones.

**Converting Postgres index types.** Most rewrite mechanically (`USING gin/gist/brin/hash` →
btree, `CONCURRENTLY` → `ASYNC`, `INCLUDE` and sort order preserved). The cases that need a
schema change:

- **Partial index** (`WHERE …`) — drop the predicate for a full index, or fold the filter
  column into a composite index.
- **Expression index** (`lower(email)`, `preferences->>'city'`) — add a
  `GENERATED ALWAYS AS (expr) STORED` column and index that. Use `STORED`, not
  `ADD COLUMN` + backfill (the gap between the two statements leaves new rows `NULL`).
- **GIN/GiST** — extract the key to a `STORED` generated column + btree, normalize arrays to a
  join table, or move full-text/fuzzy search to OpenSearch.

**Readiness:** an `ASYNC` index is unusable until it reports ready. Check with
`SELECT indexrelid::regclass, indisvalid FROM pg_index WHERE NOT indisvalid;` and don't depend
on it until `indisvalid = true`.

Source: [asynchronous indexes](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-create-index-async.html).

## Optimistic concurrency control

DSQL takes no locks; it detects conflicts at commit and aborts the loser with **SQLSTATE
`40001`**:

- **`OC000`** — data conflict (two transactions wrote the same row).
- **`OC001`** — schema/catalog conflict (stale cached catalog).

Every write transaction must be **idempotent and retried** with backoff. A workable envelope:
**up to 5 attempts**, **50 ms** base delay, exponential backoff with jitter —
`delay = min(50ms · 2^attempt + rand(0, 50ms), 5s)` — retrying **only** on `40001` and
surfacing every other error immediately; the 5 s cap keeps the loop well under the 5-minute
transaction limit. The `with_dsql_retry!` macro in `sea-query.md` implements this.

Reduce conflicts at the source: keep transactions short, use UUID v7 PKs so writes spread
across partitions, make writes idempotent (`INSERT … ON CONFLICT (id) DO NOTHING`, or a
conditional `UPDATE … WHERE`), shard hot counters, and chunk bulk writes into **100–500 row**
batches rather than filling the 3,000-row limit.

Source: [concurrency control](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-concurrency-control.html).

## Referential integrity in code

DSQL ignores `FOREIGN KEY`, so relationships are enforced in application code. The rule that
keeps this correct under OCC: **the existence check and the write run in the same
transaction.** A `SELECT` confirming the parent row adds it to the transaction's read set; if a
concurrent transaction deletes that parent and commits first, this transaction's commit is
rejected with `40001` and retries — so the check can't go stale between validate and insert. A
validation helper must be `LANGUAGE sql` (`plpgsql` is rejected); act on a false result by
raising in the application, inside that same transaction.

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

## Upstream reference

AWS publishes a DSQL skill (the `/dsql` Claude skill, Apache-2.0) that encodes much of the
above and adds a `dsql_lint` tool for live SQL-compatibility checks; install it with
`npx skills add awslabs/mcp --skill dsql --agent claude-code`. The rules here are harvested
from it but adapted to this stack, and they diverge in two places: this template uses **UUID
v7, not `SERIAL`/`IDENTITY`**, and does **not** require a `tenant_id` column (the skill assumes
multi-tenancy). Where they differ, this doc and `code-standards.md` win.

## Design checklist

- [ ] UUID v7 primary keys, client-generated; no `gen_random_uuid()` (v4) or `SERIAL`
- [ ] No foreign keys in DDL; validate relationships in code, in the write's transaction
- [ ] One DDL statement per migration file; never DDL + DML together
- [ ] Indexes on non-empty tables via `CREATE INDEX ASYNC` + `sys.wait_for_job`
- [ ] ≤ 24 indexes/table, ≤ 8 columns/index, ≤ 1 KiB key; expression/partial/GIN indexes converted
- [ ] All writes idempotent and wrapped in OCC retry
- [ ] Bulk writes chunked under the per-transaction row/byte limits
- [ ] Pool `max_lifetime` below the 60-minute connection cap; token refresh before expiry
- [ ] `numeric`/`varchar`+`CHECK`/`jsonb` instead of `money`/`enum`/custom types
- [ ] `enum` as `varchar` + inline `CHECK` at `CREATE TABLE`; ≤ 10 schemas per database
