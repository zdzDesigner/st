Title: Search write-model deepening first slice
Status: completed

## Scope

- `st.c:searchapplycursor()`
- `st.c:searchapplyinputclear()`
- `st.c:searchapplyfloweffect()`

## Change

- Added `searchapplyfloweffect()` as the single C executor for `refresh_search` vs view-only effects.
- Kept query/input/matches buffer ownership in C.
- Did not add new Zig ABI.

## Decision

This slice keeps the current ownership boundary and only reduces duplicated C orchestration. Further Search ownership work should target a larger `SearchModel` transition contract rather than moving raw buffers prematurely.
