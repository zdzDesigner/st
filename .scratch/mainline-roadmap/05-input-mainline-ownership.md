Title: Mainline 5 Input/Mainline Ownership
Status: completed

## Goal

Evaluate whether `tputc()` / ESC / control flow can move further toward Zig ownership.

## Findings

- Input already consumes `InputControlPlan`, `InputEscPlan`, `InputEscFlowPlan`, `PutcPrepare`, and write plans.
- C still naturally owns terminal global updates, STR buffer allocation, glyph writes, PTY/X11 effects, and string sequence resource lifetimes.

## Decision

No code slice in this pass. Further movement must be a deliberate input state ownership project, not another helper consolidation.

## Reopen trigger

Reopen after choosing an owner for `term.esc`, string collection, or glyph write state.
