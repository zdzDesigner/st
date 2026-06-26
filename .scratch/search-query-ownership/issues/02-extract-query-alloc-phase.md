Title: 抽出 Search query alloc phase seam
Status: completed

## What to build

把 `searchset()` 里 alloc 阶段的 `st_searchsetupdate(..., query_len, 0)` 和 `xmalloc(result.alloc_len * sizeof(*runes))` 收口到单一 helper。这个 slice 只隔离 alloc phase，不迁 `query` ownership。

## Acceptance criteria

- [x] `searchset()` 不再原地展开 alloc phase
- [x] 新 seam 只负责 alloc 阶段，不接管 `search.query` 生命周期
- [x] `zig build abi-check`、`zig build test`、`zig build` 通过

## Blocked by

- `.scratch/search-query-ownership/issues/01-design-query-ownership-seam.md`
