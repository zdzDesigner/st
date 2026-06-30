Title: Search state result carries input state
Status: completed

## Goal

Make clear/commit/cancel state actions expose the post-action input scalar state directly.

## Change

- `ZigSearchStateResult` now carries `ZigSearchInputState`.
- `searchapplyinputclear()` consumes `result.input` instead of extracting input state from `result.update`.

## Boundary

C still clears/frees the real `search.input` buffer. Zig owns the post-action input scalar decision.
