Title: Mainline 2 Term Dirty Ownership
Status: completed

## Goal

Evaluate `term.dirty` as the first `term` state ownership foothold.

## Findings

- Dirty range normalization already lives in Zig through `st_tsetdirtrange()`.
- Dirty mutation is centralized in `termapplydirtyrange()`.
- Draw dirty iteration is already plan-driven through `ZigDrawExecPlan` and `ZigDrawRegionPlan`.

## Decision

No code slice in this pass. Remaining dirty operations are C state effects. A larger `term` ownership project is required before more movement is useful.

## Reopen trigger

Reopen only with a broader `TermState` owner design that covers more than dirty range writes.
