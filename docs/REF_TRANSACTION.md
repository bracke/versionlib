# Ref transaction contract

`Version.Ref_Transaction` is the required path for production code that mutates semantic refs outside the low-level `Version.Refs` implementation. Branch, tag, stash, replay, fetch, push, and other command-level ref changes should use transactions with explicit expected-old values when the caller knows the intended previous state.

## Expected-old values

Each staged update or delete may carry an `Expected_Old` string:

- Empty string: unchecked update or delete. Use this only when the caller intentionally accepts the current ref state.
- Forty-zero object id: the ref must be missing. This is the create-only contract for new branches, tags, and tracking refs.
- Hex object id: the ref must resolve to that exact object id before any transaction writes are applied. This is the stale-update protection used by ref advances, renames, fetch tracking updates, and push bookkeeping.

Expected-old validation happens before lock acquisition and before ref files or packed refs are rewritten. A mismatch must fail the whole transaction before any new destination ref is materialized.

## Diagnostics

Stable expected-old diagnostics are produced through `Version.Ref_Transaction` helpers:

- `Invalid_Expected_Old_Diagnostic`
- `Expected_Missing_Ref_Diagnostic (Ref_Name)`
- `Expected_Old_Mismatch_Diagnostic (Ref_Name)`

Tests should compare against these helpers instead of duplicating string literals. This keeps user-visible wording frozen while giving the implementation one authoritative place for the text.

## Rollback and cleanup

A failed transaction must preserve preexisting refs and packed-ref state. If an operation has already applied before a later operation fails, rollback must remove partial destination refs, restore backed-up loose refs, restore packed refs when a packed delete was staged, remove transaction lock files, and remove rollback artifacts allocated by the transaction.

Preexisting rollback-looking sidecar files are caller-owned data and must not be deleted as cleanup. Transaction tests cover generated rollback collision handling, packed-ref restore, stale expected-old failures, stale locks, path conflicts, and rename-style update/delete failures.

## Release guardrails

`tools/bin/check_ref_write_policy` prevents production callers from bypassing the transaction layer with direct `Atomic_Write_Ref` usage outside `Version.Refs`. `tools/bin/check_release_ready` runs that policy check, its selftest, the full AUnit suite, and the release/package consistency checks.
