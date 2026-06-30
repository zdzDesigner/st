Title: Mainline 3 Selection Ownership Review
Status: completed

## Goal

Check whether Selection still contains C-owned semantic decisions worth moving to Zig.

## Findings

- Selection state updates already use snapshot/update/effect contracts.
- `selsnap()` uses Zig iterator/step logic while C reads `TLINE(...)`, delimiter, line length, and wrap facts.
- `getsel()` uses `st_getselexecplan()` while C executes malloc, UTF-8 encoding, and clipboard text construction.

## Decision

No code slice in this pass. Remaining work is C fact reading or resource/platform effect.

## Reopen trigger

Reopen only when a new selection feature duplicates semantic rules in C.
