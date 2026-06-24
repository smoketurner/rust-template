# Git Branching

Branch naming conventions for the project.
This file is read by `/rust-agents:solve-issue` to derive branch names from GitHub issues.
Customize the conventions below for this project.

## Branch Naming

- Features: `feat/m{N}/{issue-number}-{feature-slug}` where N is the milestone number
- Bug fixes: `fix/{issue-number}-{short-slug}`
- Hotfixes: `hotfix/{issue-number}-{short-slug}`
- If no issue exists, omit the issue number segment
- If no milestone, use `feat/issue-{number}/{feature-slug}`
- Examples: `feat/m3/42-auth-module`, `fix/58-null-pointer`, `hotfix/99-crash-on-startup`

## Workflow

- For each new issue, use `/rust-agents:solve-issue <number>` to create a branch and start development
- For multi-issue batches, use `/rust-agents:triage-and-solve` to prioritize and group
- Never push directly to `main` — open a PR from a feature branch

## Before Creating a PR

Pre-commit checks (these require at least one crate under `crates/`):

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --locked --workspace
cargo deny check
```

- Formatting runs on **stable** (`.rustfmt.toml` uses stable-only options — no nightly needed)
- Update `CHANGELOG.md` (`[Unreleased]` section if no version assigned)
- If you touched the data layer, run migrations against both SQLite and a Postgres/DSQL
  target (see `docs/migrations.md`)
- If you touched the UI, rebuild Tailwind CSS (`make css-build`) before committing
