Title: Search cursor delete transaction carries input state
Status: completed

## Goal

Make cursor delete actions consume one Zig-produced transaction result instead of chaining through a second delete planner in C.

## Change

- `ZigSearchCursorResult` now carries `ZigSearchInputState`.
- Cursor delete results include the post-delete input scalar state.
- `searchapplycursor()` now calls `searchapplycursordelete()` directly and no longer re-enters `st_searchdeleteplan()`.

## Boundary

C still performs the `memmove()` on `search.input`; Zig owns the scalar state and delete range decision for cursor edits.

## Next

The next slice should evaluate whether `searchapplyinputdelete()` can be limited to external/manual deletion callers, or folded into a more general input mutation executor.
