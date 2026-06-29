Title: 为 SearchMatchesState 增加边界测试
Status: completed

## What to build

围绕 `SearchMatchesState` 补测试，验证 `count/cap` 视图与 `st_searchscanlineiter/st_searchscanupdate` 的边界行为保持稳定。这个 slice 只验证标量边界，不要求迁移 `search.matches` ownership。

## Acceptance criteria

- [x] 覆盖 `count/cap` 在 grow、append、scan normalize 过程中的关键行为
- [x] 覆盖至少一组 `searchmatch/searchcurrent/searchjump` 对共享 matches 状态的读取行为
- [x] 新测试不要求迁移 `search.matches` 指针 ownership

## Blocked by

- `.scratch/search-matches-seam/issues/02-adopt-searchmatchesstate.md`
