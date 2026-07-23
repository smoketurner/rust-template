//! Dependency-anchor crate. Intentionally contains no code.
//!
//! This crate exists only so the workspace has a member and a `Cargo.lock`.
//! Its `Cargo.toml` declares every entry of the root `[workspace.dependencies]`
//! menu under `[target.'cfg(any())'.dependencies]`. `cfg(any())` is always
//! false, so cargo never compiles those crates on any platform, yet it still
//! resolves them into `Cargo.lock`. The effect:
//!
//! - `cargo update` and Dependabot see and bump every pinned version, because
//!   both read the manifest and `Cargo.lock`, which record the whole menu.
//! - `cargo build`, `cargo clippy`, and `cargo test` compile only this empty
//!   library, so CI stays fast even under `--all-features`.
//!
//! Note: because the anchored deps are unreachable in the build graph,
//! `cargo deny` and `cargo audit` (which walk reachable deps) do not scan them
//! here — they scan each dependency once a real member crate actually uses it.
//!
//! Do not add code here. When you add a dependency to the root
//! `[workspace.dependencies]` menu, mirror it into this crate's manifest.
//!
//! Delete this crate once real member crates under `crates/` cover the menu.
