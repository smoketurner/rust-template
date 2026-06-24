# Data layer: SQLite ↔ Aurora DSQL

One code path, two backends, selected at runtime by the `DATABASE_URL` scheme:

| Environment | URL | Backend |
|---|---|---|
| Tests | `sqlite::memory:` | SQLite, in-memory |
| Local dev | `sqlite://app.db?mode=rwc` | SQLite, on-disk (WAL) |
| Production | `postgres://admin@<cluster>.dsql.<region>.on.aws/postgres` | Aurora DSQL (IAM auth) |

Read `dsql.md` first — DSQL's constraints shape everything here. Queries are built with
sea-query (`sea-query.md`); this file covers connecting and pooling.

## Pool abstraction

Wrap the two sqlx pool types in one enum so callers never branch on backend:

```rust
#[derive(Clone)]
pub enum Pool {
    Sqlite(sqlx::SqlitePool),
    Postgres(sqlx::PgPool),
}

enum Backend { Sqlite, Postgres }

impl Backend {
    fn from_url(url: &str) -> anyhow::Result<Self> {
        if url.starts_with("sqlite:") {
            Ok(Self::Sqlite)
        } else if url.starts_with("postgres://") || url.starts_with("postgresql://") {
            Ok(Self::Postgres)
        } else {
            anyhow::bail!("unsupported DATABASE_URL scheme: {url}")
        }
    }
}

impl Pool {
    pub async fn connect(url: &str) -> anyhow::Result<Self> {
        match Backend::from_url(url)? {
            Backend::Sqlite => connect_sqlite(url).await,
            Backend::Postgres => connect_dsql(url).await,
        }
    }
}
```

The backend dispatch for queries lives in `sea-query.md` (the `db_fetch_*!` macros).

## SQLite (local & tests)

```rust
use std::time::Duration;
use sqlx::sqlite::{SqliteAutoVacuum, SqliteConnectOptions, SqliteJournalMode, SqliteSynchronous};

async fn connect_sqlite(url: &str) -> anyhow::Result<Pool> {
    let opts = url
        .parse::<SqliteConnectOptions>()?
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Normal)
        .auto_vacuum(SqliteAutoVacuum::Incremental)
        .busy_timeout(Duration::from_secs(5));

    let pool = sqlx::SqlitePool::connect_with(opts).await?;
    Ok(Pool::Sqlite(pool))
}
```

`sqlite::memory:` gives each test an isolated database with zero setup. WAL + `Normal`
synchronous is the standard local-dev tuning.

## Aurora DSQL (production)

DSQL has no password — you connect with a short-lived IAM token. Generation is local
(SigV4, no network call) via `aws-sdk-dsql`:

```rust
use aws_config::{BehaviorVersion, Region};
use aws_sdk_dsql::auth_token::{AuthTokenGenerator, Config as DsqlAuthConfig};

/// Generate a DSQL IAM auth token (used as the Postgres password).
async fn dsql_token(hostname: &str, region: &str, admin: bool) -> anyhow::Result<String> {
    let sdk_config = aws_config::load_defaults(BehaviorVersion::latest()).await;
    let generator = AuthTokenGenerator::new(
        DsqlAuthConfig::builder()
            .hostname(hostname)
            .region(Region::new(region.to_owned()))
            .build()?,
    );
    let token = if admin {
        generator.db_connect_admin_auth_token(&sdk_config).await?
    } else {
        generator.db_connect_auth_token(&sdk_config).await?
    };
    Ok(token.to_string())
}
```

Build the pool with the token as the password, TLS verification on, and a `max_lifetime`
**below DSQL's ~60-minute connection cap** so connections recycle cleanly:

```rust
use std::time::Duration;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions, PgSslMode};

async fn connect_dsql(url: &str) -> anyhow::Result<Pool> {
    let parsed = url::Url::parse(url)?;
    let host = parsed.host_str().context("DSQL url missing host")?.to_owned();
    let region = region_from_host(&host)?;            // parse `...dsql.<region>.on.aws`
    let user = if parsed.username().is_empty() { "admin" } else { parsed.username() };

    let token = dsql_token(&host, &region, user == "admin").await?;

    let connect_opts = PgConnectOptions::new()
        .host(&host)
        .port(5432)
        .database("postgres")
        .username(user)
        .password(&token)
        .ssl_mode(PgSslMode::VerifyFull);

    let pool = PgPoolOptions::new()
        .max_connections(10)
        .min_connections(1)
        .max_lifetime(Duration::from_secs(55 * 60))   // < DSQL's 60-min cap
        .idle_timeout(Duration::from_secs(300))
        .acquire_timeout(Duration::from_secs(5))
        .test_before_acquire(false)
        .before_acquire(|conn, meta| Box::pin(async move {
            if meta.idle_for.as_secs() > 30 {
                sqlx::Connection::ping(conn).await?;
            }
            Ok(true)
        }))
        .connect_with(connect_opts)
        .await?;

    Ok(Pool::Postgres(pool))
}
```

TLS goes through rustls + aws-lc-rs — enable sqlx's `tls-rustls-aws-lc-rs` feature and
install the provider at startup (`crypto.md`).

## Token rotation (the part to get right)

A DSQL token is only used to **establish** a connection; once connected, the session stays
valid for the connection's lifetime regardless of token expiry. But a pool opens new
connections throughout its life, and a token is valid for ~15 minutes by default — so new
connections opened later need a **fresh** token.

Options, simplest to most robust:

1. **AWS DSQL SQLx connector** — AWS publishes a connector that handles IAM tokens, TLS, and
   pooling for you. Prefer it in production; see the
   [Rust SQLx connector guide](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/SECTION_program-with-dsql-connector-for-rust-sqlx.html).
2. **Periodic pool rebuild** — hold the pool behind `tokio::sync::RwLock<PgPool>` (or
   `arc-swap`), and a background task regenerates the token and rebuilds the pool before the
   token's expiry. Drain the old pool after the swap.
3. **Longer token TTL + short pool lifetime** — request a token TTL that comfortably exceeds
   `max_lifetime`, and rebuild before it lapses.

Whatever you choose, keep `max_lifetime` under the 60-minute connection cap and make the
refresh interval shorter than the token TTL.

## Testing

```rust
async fn test_pool() -> Pool {
    let pool = Pool::connect("sqlite::memory:").await.expect("connect");
    crate::migrate(&pool).await.expect("migrate");  // see migrations.md
    pool
}
```

Every test gets a fresh, isolated in-memory database. The Postgres/DSQL path is verified
against a real cluster (or vanilla Postgres for wire-compatible smoke tests) plus the
DSQL-specific checks in `dsql.md`.
