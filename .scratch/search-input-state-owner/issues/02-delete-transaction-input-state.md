Title: Search input delete transaction returns input state
Status: completed

## Goal

Stop C from locally deriving search input scalar state after delete transactions.

## Change

- `ZigSearchDeletePlan` now carries `ZigSearchInputState`.
- `st_searchdeleteplan()` returns the post-delete input scalar state.
- `searchapplyinputdelete()` now writes the Zig-produced input state instead of mutating `input.len` locally.

## Boundary

C still performs `memmove()` on `search.input`; Zig owns the scalar decision for the post-delete input state.

## Next

The next ownership slice should consider replacing `st_searchdeleteplan(start, end, inputlen)` with a wider delete transaction that can also express cursor movement and refresh effect in one result.
