Title: Search input mutation executor
Status: completed

## Goal

Centralize the C-side execution of search input buffer mutations while keeping scalar decisions in Zig.

## Change

- Added `SearchInputMutation` as the C-side executor payload.
- Added `searchapplyinputmutation()` to execute realloc, memmove, memcpy, clear and input scalar writeback.
- Routed insert, cursor delete, manual delete and clear through the shared mutation executor.

## Boundary

Zig owns mutation decisions and post-mutation input scalar state. C still owns the actual `char *search.input` buffer and byte-level effects.

## Next

The remaining meaningful step is an explicit buffer ownership decision. Without moving `char *search.input`, further changes are mostly executor reshaping.
