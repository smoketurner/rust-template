# Migrations

Two backends, two migration directories, two runners. SQLite uses sqlx's standard
transactional migrator; DSQL needs a custom runner because it rejects DDL inside multi-
statement transactions and builds indexes asynchronously (see `dsql.md`).

```
crates/<name>-server/
  migrations/
    sqlite/
      0001_create_notes.sql
    postgres/        # Aurora DSQL-compatible
      0001_create_notes.sql
      0002_idx_notes_created_at.sql
```

## Authoring rules (postgres/ dir)

- **One DDL statement per file.** Never mix DDL and DML in one file.
- **UUID v7 primary keys** (client-supplied, `uuid::Uuid::now_v7()`), no `SERIAL`. No `FOREIGN KEY`.
- **Indexes in their own file** using `CREATE INDEX ASYNC` (synchronous `CREATE INDEX` only
  works on empty tables).
- Keep the SQLite copy semantically equivalent; differences (e.g. `TEXT` vs `uuid`) are fine
  as long as the columns line up.

```sql
-- postgres/0001_create_notes.sql  (one DDL statement, no FK, client-supplied UUID v7 PK)
CREATE TABLE notes (
    id         UUID PRIMARY KEY,
    title      VARCHAR(200) NOT NULL,
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

```sql
-- postgres/0002_idx_notes_created_at.sql  (async; not wrapped in a transaction)
CREATE INDEX ASYNC idx_notes_created_at ON notes (created_at);
```

```sql
-- sqlite/0001_create_notes.sql
CREATE TABLE notes (
    id         TEXT PRIMARY KEY,
    title      TEXT NOT NULL,
    body       TEXT NOT NULL,
    created_at TEXT NOT NULL
);
```

## Running them

```rust
pub async fn migrate(pool: &Pool) -> anyhow::Result<()> {
    match pool {
        Pool::Sqlite(p) => {
            sqlx::migrate!("./migrations/sqlite").run(p).await?;
        }
        Pool::Postgres(p) => run_dsql_migrations(p).await?,
    }
    Ok(())
}
```

SQLite gets the built-in transactional migrator for free.

## DSQL runner

The custom runner applies each pending migration **outside a transaction**, then records it
in `_sqlx_migrations`. Because a retry can re-run a DDL that already partially applied, it
tolerates "already exists" errors and moves on.

```rust
use sqlx::{migrate::Migrator, PgPool, Row};

static MIGRATOR: Migrator = sqlx::migrate!("./migrations/postgres");

async fn run_dsql_migrations(pool: &PgPool) -> anyhow::Result<()> {
    ensure_migrations_table(pool).await?;
    let applied = applied_versions(pool).await?;

    for migration in MIGRATOR.iter() {
        if migration.migration_type.is_down_migration() || applied.contains(&migration.version) {
            continue;
        }

        // One statement per file => safe to send as a single DDL outside a transaction.
        match sqlx::raw_sql(&migration.sql).execute(pool).await {
            Ok(_) => {}
            Err(e) if is_already_exists(&e) => {
                tracing::warn!(version = migration.version, "object already exists — recording as applied");
            }
            Err(e) => return Err(e.into()),
        }

        record_applied(pool, migration.version, &migration.description).await?;
        tracing::info!(version = migration.version, "applied migration");
    }
    Ok(())
}

async fn ensure_migrations_table(pool: &PgPool) -> anyhow::Result<()> {
    sqlx::raw_sql(
        "CREATE TABLE IF NOT EXISTS _sqlx_migrations (
             version BIGINT PRIMARY KEY,
             description TEXT NOT NULL,
             applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
         )",
    )
    .execute(pool)
    .await?;
    Ok(())
}

async fn applied_versions(pool: &PgPool) -> anyhow::Result<Vec<i64>> {
    let rows = sqlx::query("SELECT version FROM _sqlx_migrations").fetch_all(pool).await?;
    Ok(rows.iter().map(|r| r.get::<i64, _>("version")).collect())
}

async fn record_applied(pool: &PgPool, version: i64, description: &str) -> anyhow::Result<()> {
    sqlx::query("INSERT INTO _sqlx_migrations (version, description) VALUES ($1, $2)")
        .bind(version)
        .bind(description)
        .execute(pool)
        .await?;
    Ok(())
}

fn is_already_exists(e: &sqlx::Error) -> bool {
    // Postgres SQLSTATE 42P07 (duplicate_table) / 42710 (duplicate_object).
    matches!(
        e.as_database_error().and_then(|d| d.code()),
        Some(code) if code == "42P07" || code == "42710"
    )
}
```

## Async indexes

`CREATE INDEX ASYNC` returns a `job_id` and builds in the background. If a later migration or
query depends on the index, wait for it:

```sql
SELECT * FROM sys.wait_for_job('<job_id>');
```

For a template-scale schema, creating the index in its own migration and letting it finish
asynchronously is usually enough; add the `wait_for_job` step only when a subsequent step
truly needs the index present.

## Verifying both backends

Run the SQLite migrations in every test via the in-memory pool (`database.md`). Run the
Postgres migrations against a real DSQL cluster (or vanilla Postgres for a wire-compatible
smoke test) in a pre-release check — the two migrators behave differently and only live
runs catch DSQL DDL rejections.
