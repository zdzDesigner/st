Title: Batch 4 input mainline ownership
Status: completed

## Goal

Assess whether `tputc()` / ESC / control flow can be safely moved further toward Zig ownership.

## Findings

- Input already consumes `InputControlPlan`, `InputEscPlan`, `InputEscFlowPlan`, `PutcPrepare` and write plans.
- C still owns terminal global updates, STR buffer allocation, glyph writes and platform effects.
- Moving further would require ownership migration for `term.esc`, string sequence buffers or glyph write state.

## Decision

Batch 4 is closed as a low-risk batch. Input mainline should only continue as a deliberate state ownership project.

## Reopen trigger

Reopen after a concrete state owner is chosen for `term.esc`, string collection, or glyph write state.
