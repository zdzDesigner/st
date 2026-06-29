Title: Selection state/flow deepening first slice
Status: completed

## Scope

- `st.c:selstart()`
- `st.c:selextend()`
- `st.c:selectionapplyresult()`

## Change

- Added `selectionapplyresult()` to centralize state apply plus dirty effect execution.
- Kept glyph reads, text allocation, UTF-8 encoding and clipboard output in C.
- Did not add new Zig ABI.

## Decision

Selection should continue using snapshot/update/effect boundaries. The next worthwhile slice should reduce semantic flow knowledge in C, not move clipboard or glyph access ownership prematurely.
