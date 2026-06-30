Title: Selection ownership boundary review
Status: completed

## Decision

No code slice in this pass.

## Reason

Selection state already uses snapshot/update/effect. Remaining work is `TLINE(...)` fact reading, malloc, UTF-8 encoding and clipboard output, which stay in C.

## Reopen Trigger

Reopen only if a new selection feature duplicates semantic rules in C.
