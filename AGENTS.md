# AGENTS.md

Guidance for AI coding agents lives in **[CLAUDE.md](CLAUDE.md)** — the stack, repository
layout, conventions, commands, and the review gates under `.claude/rules/`. Read it first.

## System dependencies (Linux)

Building the stack needs `cmake` and `clang` (the `aws-lc-rs` crypto provider compiles C).
On Debian/Ubuntu:

```bash
sudo apt-get update && sudo apt-get install -y cmake clang
```

macOS runners and dev machines already have a suitable toolchain.
