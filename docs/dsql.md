# Amazon Aurora DSQL constraints

Aurora DSQL speaks the PostgreSQL 16 wire protocol but is a distributed, serverless engine
with **optimistic concurrency control** and a restricted SQL surface. Schema and migrations
must be written for DSQL, not vanilla Postgres. This is the reference; `migrations.md` and
`database.md` show the code.

> Quotas and the supported-SQL list change. Last verified against the
> [Aurora DSQL release notes](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/release-notes.html) on **2026-10-01**. Check the release notes for anything
> newer before relying on a specific limit or "unsupported" entry.

## What is not supported

| Feature | Status | What to do instead |
|---|---|---|
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
`boolean`, `bytea`, date/time/`timestamptz` (UTC), `json`/`jsonb` (≤ 1 MiB compressed), views,
`CREATE DOMAIN`, `GENERATED ALWAYS AS (expr) STORED` columns, partial and expression indexes,
`SELECT … FOR UPDATE` / `FOR KEY SHARE`, `CREATE STATISTICS`, and `FOREIGN KEY` constraints
(enforced since August 2026, but this template doesn't declare them — see
[Referential integrity in code](#referential-integrity-in-code)).

Sources: [supported SQL features](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-postgresql-compatibility-supported-sql-features.html),
[supported data types](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-postgresql-compatibility-supported-data-types.html),
[migration guide](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-postgresql-compatibility-migration-guide.html).

## Type and column rules

- **Declare `NUMERIC` precision and scale explicitly** (`numeric(20,10)`; up to precision
  1000). An unsized `numeric` silently becomes `numeric(18,6)` on DSQL, so values with more
  than six decimal places are rounded on write, unlike Postgres.
- **C collation, database-wide.** Per-column `COLLATE` is rejected, and `ORDER BY` on text
  sorts by raw byte value (uppercase before lowercase, non-ASCII after `z`). Use `lower(col)`
  for case-insensitive ordering and comparison.
- **No array columns.** Store collections as `jsonb` and expand with
  `jsonb_array_elements_text(col)` at query time.
- **`enum` → `varchar` + inline `CHECK`.** To change the allowed values later, add the new
  constraint with `ALTER TABLE … ADD CONSTRAINT … CHECK (…) NOT VALID`, validate existing rows
  with `ALTER TABLE ASYNC … VALIDATE CONSTRAINT` (an async job, like `CREATE INDEX ASYNC`),
  then `DROP CONSTRAINT` the old one — three migrations. `ALTER COLUMN … TYPE` is still
  unsupported.
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
- `ALTER TABLE` supports `ADD`/`DROP`/`RENAME COLUMN`, `RENAME`, `SET`/`DROP DEFAULT`,
  `DROP NOT NULL`, identity changes, `ADD CONSTRAINT … NOT VALID` (`CHECK` or `FOREIGN KEY`;
  an added constraint must be `NOT VALID`), `ALTER TABLE ASYNC … VALIDATE CONSTRAINT`, and
  `DROP CONSTRAINT`. You **cannot change a column's type or the primary key** after creation —
  design them up front.

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
btree, `CONCURRENTLY` → `ASYNC`; `INCLUDE`, sort order, partial `WHERE …` predicates, and
expression keys such as `lower(email)` carry over unchanged). Index expressions and partial
predicates may use only immutable functions and operators, and the planner uses a partial
index only when it can prove the query's `WHERE` implies the index predicate. SQLite supports
both forms, so the two migration sets stay aligned. The case that still needs a schema change:

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

DSQL has enforced `FOREIGN KEY` constraints since August 2026
([foreign keys](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-foreign-key-constraints.html)),
but this template still doesn't declare them. Every DML statement on a referencing or
referenced table pays extra reads to check the constraint, and each referencing write adds a
commit-time conflict on the parent row, so hot tables lose write throughput. Relationships are
enforced in application code instead.

The rule that keeps this correct under OCC: **check the parent with `SELECT … FOR KEY SHARE`
in the same transaction as the child write.** A plain `SELECT` never conflicts in DSQL — OCC
compares writes, not reads — so a parent deleted between your check and your commit would
leave an orphan. `FOR KEY SHARE` (what DSQL's own foreign keys use internally) makes a
concurrent `DELETE` of the parent, or a change to its key columns, fail whichever transaction
commits second with `40001`, and the retry re-runs the check. Updates to the parent's non-key
columns don't conflict. In sea-query that is `.lock(LockType::KeyShare)`;
`SqliteQueryBuilder` omits the clause, which is safe because SQLite allows one writer at a
time. A delete of a parent checks for children in its own transaction; the conflict between
its `DELETE` and a concurrent child's `FOR KEY SHARE` closes the race from that side.

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

## Upstream reference

AWS publishes a DSQL skill (the `/dsql` Claude skill, Apache-2.0) that encodes much of the
above and adds a `dsql_lint` tool for live SQL-compatibility checks; install it with
`npx skills add awslabs/mcp --skill dsql --agent claude-code`. The rules here are harvested
from it but adapted to this stack, and they diverge in two places: this template uses **UUID
v7, not `SERIAL`/`IDENTITY`**, and does **not** require a `tenant_id` column (the skill assumes
multi-tenancy). Where they differ, this doc and `code-standards.md` win.

## Design checklist

- [ ] UUID v7 primary keys, client-generated; no `gen_random_uuid()` (v4) or `SERIAL`
- [ ] No foreign keys in DDL; validate relationships in code with `FOR KEY SHARE` on the parent,
      in the write's transaction
- [ ] One DDL statement per migration file; never DDL + DML together
- [ ] Indexes on non-empty tables via `CREATE INDEX ASYNC` + `sys.wait_for_job`
- [ ] ≤ 24 indexes/table, ≤ 8 columns/index, ≤ 1 KiB key; GIN/GiST indexes converted to btree
- [ ] All writes idempotent and wrapped in OCC retry
- [ ] Bulk writes chunked under the per-transaction row/byte limits
- [ ] Pool `max_lifetime` below the 60-minute connection cap; token refresh before expiry
- [ ] `numeric(p,s)`/`varchar`+`CHECK`/`jsonb` instead of `money`/`enum`/custom types; every
      `numeric` declares precision and scale
- [ ] `enum` as `varchar` + inline `CHECK`; changes go through `NOT VALID` + async
      `VALIDATE CONSTRAINT`; ≤ 10 schemas per database
