Title: Term dirty ownership boundary review
Status: completed

## Decision

No code slice in this pass.

## Reason

Dirty range normalization already lives in Zig through `st_tsetdirtrange()`, while dirty array mutation is a C state effect centralized in `termapplydirtyrange()`.

## Reopen Trigger

Reopen only when designing a broader `TermState` owner that covers dirty reads, writes and draw consumption together.
