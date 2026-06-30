Title: Mainline 4 Term Cursor/Viewport Ownership
Status: completed

## Goal

Evaluate cursor and viewport state as the next `term` ownership slice.

## Findings

- Cursor clamp, newline, draw cursor adjustment, and cursor save/load action planning are already in Zig.
- C writes `term.c`, `term.ocx`, and `term.ocy` as final state effects.
- Viewport/draw orchestration is already `ZigDrawExecPlan` driven.

## Decision

No code slice in this pass. A new cursor/viewport seam would mostly wrap existing C assignments without moving decision logic.

## Reopen trigger

Reopen only as part of a larger `TermState` owner project.
