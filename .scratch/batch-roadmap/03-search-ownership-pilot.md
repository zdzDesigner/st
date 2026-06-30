Title: Batch 3 search ownership pilot
Status: completed

## Goal

Re-evaluate whether a search buffer can be safely moved toward Zig ownership.

## Findings

- `search.input` still naturally depends on C-side `xrealloc`, `memmove`, `memcpy`, nul termination and `searchset()` triggering.
- `search.query` still naturally depends on C-side UTF-8 decode and pointer replacement.
- `search.matches` still naturally depends on C-side line/history traversal, `xrealloc` and match array writes.

## Decision

Batch 3 is closed. Do not migrate search buffer ownership yet. Current transaction seams are the right boundary.

## Reopen trigger

Reopen only as a deliberate ownership project, and migrate at most one buffer class at a time.
