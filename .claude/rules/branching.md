# Git Branching

Branch naming conventions for the project.
This file is read by `/rust-agents:solve-issue` to derive branch names from GitHub issues.
Customize the conventions below for this project.

## Branch Naming

- Features: `feat/m{N}/{issue-number}-{feature-slug}` where N is the milestone number
- Bug fixes: `fix/{issue-number}-{short-slug}`
- Hotfixes: `hotfix/{issue-number}-{short-slug}`
- Other work mirrors its Conventional Commit type (see `commits-and-issues.md`):
  `{type}/{issue-number}-{short-slug}` for `docs`, `ci`, `build`, `chore`, `refactor`, …
- If no issue exists, omit the issue number segment
- If no milestone, use `feat/issue-{number}/{feature-slug}`
- Examples: `feat/m3/42-auth-module`, `fix/58-null-pointer`, `hotfix/99-crash-on-startup`,
  `docs/dsql-limits`

## Workflow

- For each new issue, use `/rust-agents:solve-issue <number>` to create a branch and start development
- For multi-issue batches, use `/rust-agents:triage-and-solve` to prioritize and group
- Never push directly to `main` — open a PR from a feature branch
- One writer per checkout. Agents editing **in parallel** each use their own worktree
  (`wt switch <branch>`, or `isolation: "worktree"` for subagents). Before reassigning
  in-flight work, stand the old agent down and snapshot its diff first (see
  `development-discipline.md`).
- PRs are squash-merged, so the PR title becomes the commit subject on `main`: write it as
  a Conventional Commit (`feat(server): add health endpoint`).

## Before Creating a PR

Pre-commit checks (these require at least one crate under `crates/`):

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --locked --workspace
cargo deny check
```

- For changes touching the **data layer, crypto/TLS, or dependencies**, verify the review
  gates in [`code-standards.md`](code-standards.md) pass (links into `docs/dsql.md`,
  `docs/migrations.md`, `docs/crypto.md`)
- Formatting runs on **stable** (`.rustfmt.toml` uses stable-only options — no nightly needed).
  Run `make fmt` before pushing; formatting is never a follow-up commit.
- **Claims about external behavior are quoted, not remembered.** Re-read every normative
  claim in the diff and the PR description ("per RFC X", "DSQL doesn't support Y", "this
  violates the spec"). Each needs a section, a verbatim quote, and a URL fetched this
  session, with its MUST/SHOULD/MAY strength reported accurately (see
  [`specs-are-source-of-truth.md`](specs-are-source-of-truth.md)).
- Update `CHANGELOG.md` (`[Unreleased]` section if no version assigned)
- If you touched the data layer, run migrations against both SQLite and a Postgres/DSQL
  target (see `docs/migrations.md`)
- If you touched the UI, rebuild Tailwind CSS (`make css-build`) before committing
