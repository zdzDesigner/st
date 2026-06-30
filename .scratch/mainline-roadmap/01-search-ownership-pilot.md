Title: Mainline 1 Search Ownership Pilot
Status: completed

## Goal

Evaluate whether Search can safely move from plan-driven C executor to Zig-owned state.

## Findings

- `SearchSnapshot` / `SearchStateUpdate` / `SearchEffectPlan` already make Zig authoritative for most search state decisions.
- `search.input` still naturally depends on C-side `xrealloc`, `memmove`, `memcpy`, nul termination, and `searchset()` triggering.
- `search.query` still naturally depends on C-side UTF-8 decode and pointer replacement.
- `search.matches` still naturally depends on terminal/history traversal, C-side `xrealloc`, and array writes.

## Decision

No code slice in this pass. Search buffer ownership is not ready to migrate. Keep the current transaction seams.

## Reopen trigger

Reopen only when intentionally choosing one buffer class as an ownership project. Do not migrate input/query/matches together.
