Title: Search input state owner first slice
Status: completed

## Goal

Move search input scalar state toward an explicit Zig-owned value boundary without migrating the `char *search.input` buffer yet.

## Change

- Added `ZigSearchInputState` as the explicit input scalar state ABI value.
- Added `st_searchinputstate()` to extract input scalar authority fields from `ZigSearchStateUpdate`.
- Replaced C-private `SearchInputState` with `ZigSearchInputState`.
- `searchapplyinputinsert()` and `searchapplyinputclear()` now consume input state from the Zig update rather than re-reading C fields after the update.

## Boundary

- C still owns `search.input` allocation, reallocation, byte movement and nul termination.
- Zig now exposes the input scalar state as a first-class value, preparing for a future owner design.

## Next

The next slice should decide whether `searchapplyinputdelete()` can also consume a Zig-produced input state/result instead of mutating the input scalar locally after `st_searchdeleteplan()`.
