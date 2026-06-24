# sea-query as the translation layer

sea-query builds each query once, then renders it for whichever backend the `Pool` holds —
`SqliteQueryBuilder` for SQLite, `PostgresQueryBuilder` for DSQL. Handlers call typed store
methods and never see SQL or the backend split.

Crates (from the workspace menu):

```toml
sea-query      = { workspace = true, features = ["backend-sqlite", "backend-postgres", "derive"] }
sea-query-sqlx = { workspace = true, features = ["sqlx-sqlite", "sqlx-postgres", "runtime-tokio"] }
sqlx           = { workspace = true, features = ["runtime-tokio", "sqlite", "postgres", "tls-rustls-aws-lc-rs", "migrate"] }
```

## Schema as an `Iden` enum

```rust
use sea_query::Iden;

#[derive(Iden)]
enum Notes {
    Table,
    Id,
    Title,
    Body,
    CreatedAt,
}
```

## Backend-dispatch macros

The only place the backend is matched. `build_sqlx` (from `sea_query_sqlx::SqlxBinder`)
returns the SQL string plus bound values; `AssertSqlSafe` tells sqlx the generated string is
trusted (values are still bound as parameters, never interpolated).

```rust
#[macro_export]
macro_rules! db_fetch_optional {
    ($pool:expr, $stmt:expr, $row:ty) => {{
        use sea_query_sqlx::SqlxBinder;
        match $pool {
            $crate::Pool::Sqlite(p) => {
                let (sql, values) = $stmt.build_sqlx(sea_query::SqliteQueryBuilder);
                sqlx::query_as_with::<_, $row, _>(sqlx::AssertSqlSafe(sql), values)
                    .fetch_optional(p).await
            }
            $crate::Pool::Postgres(p) => {
                let (sql, values) = $stmt.build_sqlx(sea_query::PostgresQueryBuilder);
                sqlx::query_as_with::<_, $row, _>(sqlx::AssertSqlSafe(sql), values)
                    .fetch_optional(p).await
            }
        }
    }};
}

#[macro_export]
macro_rules! db_fetch_all {
    ($pool:expr, $stmt:expr, $row:ty) => {{
        use sea_query_sqlx::SqlxBinder;
        match $pool {
            $crate::Pool::Sqlite(p) => {
                let (sql, values) = $stmt.build_sqlx(sea_query::SqliteQueryBuilder);
                sqlx::query_as_with::<_, $row, _>(sqlx::AssertSqlSafe(sql), values)
                    .fetch_all(p).await
            }
            $crate::Pool::Postgres(p) => {
                let (sql, values) = $stmt.build_sqlx(sea_query::PostgresQueryBuilder);
                sqlx::query_as_with::<_, $row, _>(sqlx::AssertSqlSafe(sql), values)
                    .fetch_all(p).await
            }
        }
    }};
}

#[macro_export]
macro_rules! db_execute {
    ($pool:expr, $stmt:expr) => {{
        use sea_query_sqlx::SqlxBinder;
        match $pool {
            $crate::Pool::Sqlite(p) => {
                let (sql, values) = $stmt.build_sqlx(sea_query::SqliteQueryBuilder);
                sqlx::query_with(sqlx::AssertSqlSafe(sql), values).execute(p).await
            }
            $crate::Pool::Postgres(p) => {
                let (sql, values) = $stmt.build_sqlx(sea_query::PostgresQueryBuilder);
                sqlx::query_with(sqlx::AssertSqlSafe(sql), values).execute(p).await
            }
        }
    }};
}
```

## A store method

```rust
use sea_query::{Expr, Query};

#[derive(sqlx::FromRow)]
struct NoteRow {
    id: String,
    title: String,
    body: String,
    created_at: String,
}

pub struct Store { pool: Pool }

impl Store {
    pub async fn get(&self, id: &str) -> anyhow::Result<Option<Note>> {
        let stmt = Query::select()
            .columns([Notes::Id, Notes::Title, Notes::Body, Notes::CreatedAt])
            .from(Notes::Table)
            .and_where(Expr::col(Notes::Id).eq(id))
            .to_owned();

        let row: Option<NoteRow> = db_fetch_optional!(&self.pool, stmt, NoteRow)?;
        Ok(row.map(Note::from))
    }

    pub async fn insert(&self, note: &Note) -> anyhow::Result<()> {
        with_dsql_retry!(&self.pool, async {
            let stmt = Query::insert()
                .into_table(Notes::Table)
                .columns([Notes::Id, Notes::Title, Notes::Body, Notes::CreatedAt])
                .values_panic([
                    note.id.clone().into(),
                    note.title.clone().into(),
                    note.body.clone().into(),
                    note.created_at.clone().into(),
                ])
                .to_owned();
            db_execute!(&self.pool, stmt)?;
            Ok(())
        })
    }
}
```

Generate ids client-side with `uuid::Uuid::now_v7()` (UUID v7, time-ordered) so the same
code works on both backends and you know the id before insert.

## OCC retry for DSQL writes

DSQL aborts conflicting transactions with SQLSTATE `40001` (`OC000`/`OC001`). Wrap writes so
they retry with backoff. On SQLite the predicate never matches, so the body runs once.

```rust
pub const MAX_DSQL_RETRIES: u32 = 3;

pub fn is_retryable(e: &sqlx::Error) -> bool {
    matches!(
        e.as_database_error().and_then(|d| d.code()),
        Some(code) if code == "40001"
    )
}

pub fn backoff(attempt: u32) -> std::time::Duration {
    std::time::Duration::from_millis(25u64.saturating_mul(1 << attempt.min(5)))
}

#[macro_export]
macro_rules! with_dsql_retry {
    ($pool:expr, $body:expr) => {{
        let mut attempt = 0u32;
        loop {
            match $body.await {
                Ok(v) => break Ok(v),
                Err(e) if $crate::is_retryable(&e) && attempt < $crate::MAX_DSQL_RETRIES => {
                    tokio::time::sleep($crate::backoff(attempt)).await;
                    attempt = attempt.saturating_add(1);
                }
                Err(e) => break Err(e.into()),
            }
        }
    }};
}
```

Keep retried transactions **idempotent** — that's why client-generated ids and
upsert-friendly writes matter (`dsql.md`).

The constants here (3 retries, 25 ms base, no jitter) are deliberately small for a template.
`dsql.md` records AWS's fuller envelope — up to 5 attempts, 50 ms base, jitter, 5 s cap — widen
toward it under real contention.
