# Crypto & TLS: aws-lc-rs only

This template uses **aws-lc-rs** as the single crypto provider, everywhere — for rustls TLS
(DSQL, outbound HTTPS) and any signing. OpenSSL and `ring` are deliberately kept out: they're
banned in `deny.toml` and excluded by feature selection.

Why: one audited, FIPS-capable provider; no system OpenSSL to cross-compile or patch; a
smaller attack surface; and no ambiguity about which backend rustls picks at runtime.

## Install the default provider once, at startup

rustls requires a process-wide default `CryptoProvider`. Install aws-lc-rs as the very first
thing in `main`, before any TLS connection (pool, HTTP client) is created:

```rust
fn main() -> anyhow::Result<()> {
    rustls::crypto::aws_lc_rs::default_provider()
        .install_default()
        .map_err(|_| anyhow::anyhow!("default crypto provider already installed"))?;

    // ... build runtime, pools, server ...
    Ok(())
}
```

`install_default` returns `Err` if a provider is already set, so the `map_err` keeps the
strict `unwrap_used`/`expect_used` lints satisfied. When you need an explicit config (e.g. a
custom `ClientConfig`), build it from the provider directly:

```rust
let config = rustls::ClientConfig::builder_with_provider(
        std::sync::Arc::new(rustls::crypto::aws_lc_rs::default_provider()),
    )
    .with_safe_default_protocol_versions()?
    .with_root_certificates(root_store)
    .with_no_client_auth();
```

## Feature selection

Enable the aws-lc-rs path on every TLS-using crate, with default features off so no other
backend sneaks in:

```toml
rustls       = { workspace = true, features = ["aws_lc_rs", "std", "tls12"] }
tokio-rustls = { workspace = true, features = ["aws-lc-rs"] }
sqlx         = { workspace = true, features = ["tls-rustls-aws-lc-rs", /* runtime-tokio, postgres, sqlite, migrate */] }
webpki-roots = { workspace = true }
```

If you add an HTTP client (`reqwest`) or JWTs (`jsonwebtoken`), pick their `rustls` +
`aws-lc-rs` features too — never `native-tls`, `default-tls`, or a `ring` feature. (Optional:
rustls' `prefer-post-quantum` feature enables hybrid key exchange.)

## Enforce it

`deny.toml` already denies `openssl`, `openssl-sys`, `native-tls`, and `ring`, so a stray
feature fails `cargo deny check`. Double-check the resolved graph after wiring up TLS:

```bash
cargo tree -i ring          # expect: "package ID specification ... did not match any packages"
cargo tree -i openssl-sys   # expect: no match
cargo tree -i aws-lc-rs     # expect: aws-lc-rs present, pulled by rustls/sqlx
```

An empty result for `ring`/`openssl-sys` and a present `aws-lc-rs` confirms the single-
provider setup. Make `cargo deny check` part of CI (it already is) so regressions are caught
on every PR.
