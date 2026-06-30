Title: Term cursor viewport ownership boundary review
Status: completed

## Decision

No code slice in this pass.

## Reason

Cursor movement, newline, draw cursor adjustment and draw frame planning are already in Zig. C field writes are final state effects.

## Reopen Trigger

Reopen only as part of a broader `TermState` owner design.
