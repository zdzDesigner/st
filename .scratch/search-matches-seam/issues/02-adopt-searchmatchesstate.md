Title: 引入 SearchMatchesState 并扩大采用范围
Status: completed

## What to build

引入 `SearchMatchesState`，统一承载 `matches` 相关的 `count/cap` 标量视图，并让 `searchscan/searchscanline/searchjump/searchmatch/searchcurrent` 优先通过这个 seam 读取共享状态。这个 slice 不迁移 `search.matches` 指针或其资源所有权。

## Acceptance criteria

- [x] 新增 `SearchMatchesState` 共享视图，至少覆盖 `count` 与 `cap`
- [x] 一批 Search 调用点改为通过 `SearchMatchesState` 读取/写回 `matches` 标量状态
- [x] `zig build abi-check`、`zig build test`、`zig build` 通过

## Blocked by

- `.scratch/search-matches-seam/issues/01-design-matches-seam.md`
