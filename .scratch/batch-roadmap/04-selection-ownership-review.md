Title: Batch 5 selection ownership review
Status: completed

## Goal

Review whether selection still contains C-owned semantic decisions that should move to Zig.

## Findings

- Selection state updates are already snapshot/update/effect driven.
- `selsnap()` uses Zig step/iterator logic while C reads `TLINE(...)`, delimiter, line length and wrap facts.
- `getsel()` uses `st_getselexecplan()` while C executes malloc, UTF-8 encoding and clipboard text construction.

## Decision

Batch 5 is closed. Remaining work is natural C fact reading or platform/resource effect.

## Reopen trigger

Reopen only if a new selection feature duplicates semantic selection rules in C.
