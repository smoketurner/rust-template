# Specifications Are the Source of Truth

Read by every agent before implementing, reviewing, or describing behavior that an
external document defines: an RFC, a protocol spec, an AWS service guide (Aurora DSQL
limits and concurrency rules), or a library's documented contract. A wrong assumption
about that text ships as a defect that looks correct in review.

## The rule

**Never state what a specification or service requires from memory. Open it.**

Model training data reproduces the *shape* of a spec sentence reliably and its *content*
unreliably. The failure is not "I don't know" — it is a fluent, plausible,
correctly-formatted sentence that is not in the document, which is indistinguishable from
a real citation at review time. This template once documented that a plain `SELECT` puts
a row in DSQL's conflict set; AWS's concurrency-control guide says reads never conflict
without `FOR UPDATE` / `FOR KEY SHARE`, so the documented pattern allowed orphan rows.

Service docs drift as well: a limit or "unsupported" feature that was true last year may
not be now. Re-check the current page before relying on one. A doc in this repo that
restates a service's rules (`docs/dsql.md`, `docs/migrations.md`) carries a "last verified"
date: whoever re-checks it against the source updates that date, even when nothing else
changes, and an edit that didn't re-check the whole doc leaves the date alone.

This applies to reviews and PR descriptions as much as to code. "This violates the spec"
or "DSQL doesn't support X" is a normative claim and needs the same evidence as the code.

## What a citation must contain

A claim about required behavior is only supported by all three:

1. The document and section — "RFC 9110 §15.5.1", "Aurora DSQL User Guide, Concurrency
   control", not "the spec" or "the AWS docs".
2. A **verbatim quote** of the sentence carrying the requirement.
3. The URL it was fetched from in this session.

Without the quote it is not a citation. `// per RFC 9449` on its own records that someone
believed something, not what the document says.

## Verify the fetch, not just the answer

Summarizers hallucinate normative text. When a quote is load-bearing — it decides a
behavior, settles a review, or justifies a merge — confirm it against a second source or
a targeted search for the exact phrase. If the phrase cannot be found again, it is not
real.

## MUST, SHOULD, MAY are not interchangeable

Report the actual strength. A MAY means both behaviors conform, so the choice is a product
decision, not a compliance one. A SHOULD deviation is not a "violation". A MUST with no
escape clause is. Downgrading a MUST hides a real defect; upgrading a MAY invents work and
burns credibility on the findings that matter.

## Silence is an answer, and it is not permission

If a document does not address a case, say so explicitly. "The guide does not mention
error responses" is a finding: the decision is ours and should be justified on its merits
— interop, security, least surprise — rather than dressed up as conformance.

## When the spec contradicts an earlier decision

The spec wins, including over a decision recorded in this repo's docs or a merged PR.
Surface the contradiction with the quote rather than quietly following local convention:
a merged choice that is less strict than the spec is a live gap, not settled precedent.
