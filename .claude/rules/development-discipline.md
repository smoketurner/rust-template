# Development Discipline

How agents carry out work in this repo. Read by `rust-team`, `rust-code-reviewer`,
and `/rust-agents:solve-issue` before design, implementation, or review. These
complement [`code-standards.md`](code-standards.md): that file covers *what* the code
must be, this one covers *how* the work is done.

## Design decisions

1. **Operator-facing workflow models are user decisions.** When a design chooses
   between automated and operator-driven behavior (schedules, cleanup, approvals),
   present every viable model — including the fully-manual one — before
   implementation. An architect or critic may recommend and rank; it may not silently
   eliminate a model the user would recognize from other products.
2. **Lead with prior art.** Before proposing a novel operational design, survey how
   established systems solve it (AWS KMS, Auth0, Vault, ACME, DNSSEC rollover) and
   name the model being followed. A design anchored as "this is Auth0's rotate/revoke
   model" settles in one round; an unanchored one churns.
3. **Explain with artifacts, not abstractions.** Proposals for UI or operational
   behavior must show the concrete experience: button labels, exact warning text,
   timelines with real hours. If the user asks "what do you mean by X" twice, stop
   describing and draw the screen.
4. **State the cost before building.** Before implementation starts, give the expected
   size (files, rough line count) and the slimmest viable alternative. A one-question
   scope checkpoint is cheaper than a rework.

## Implementation

5. **The design's type plan is part of the contract.** If the approved design names
   shared types or helpers (one enum, one ID function), the implementation ships them.
   Three functions differing only in a constant, or two enums encoding the same fact,
   is a rewrite — not a review nit.
6. **Fix the class, not the instance.** When a bug reveals an invariant ("every key
   mutation must invalidate the cache"), enumerate every code path that touches the
   invariant and fix them all in one pass. Piecemeal fixes invite N more review rounds
   finding the same bug's siblings.
7. **Scripted bulk edits must prove they landed.** Text replacement that no-ops on a
   missed anchor (`str.replace`, `sed`) silently drops changes. After any scripted
   edit, grep for the new text AND the absence of the old; an edit that changed
   nothing is a failure, not a success. Prefer edit tools that error on a missed match.
8. **Completion reports need evidence.** "Done, all tests pass" is accepted only with
   the commands run and their actual counts. The recipient greps the diff for the
   claimed artifacts (new tests, new functions) before advancing the pipeline.

## Diagnostics and retries

9. **Diagnostics are read-only.** Never inspect config with positional arguments —
   `git config <key> <value>` is the WRITE syntax, and one such "read" can break commit
   signing for the whole repo. Use `git config --get` / `--list --show-origin`. The
   same caution applies to any tool where read and write share a verb.
10. **Three strikes, then re-diagnose.** If the same command fails three times, stop
    retrying and re-verify the diagnosis from scratch (traces, logs, changed state).
    The failure cause can change *while* retrying.

## Agent teams

11. **Judge liveness by evidence, not silence.** Before declaring a teammate stuck,
    check the filesystem: source mtimes, `target/` fingerprints, new handoff files. A
    quiet agent may be mid-compaction; a "running" one may have produced nothing.
12. **Stand down before reassigning.** Never let two writers share a working tree: send
    an explicit stand-down, snapshot the diff to a patch file, and only then hand the
    work to a replacement.
