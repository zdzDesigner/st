Title: 抽出 Search query replace transaction seam
Status: completed

## What to build

把 `searchset()` 里围绕 query 替换的关键时序收口到单一 helper：`clear_query` effect、`search.query = runes` 指针替换、`searchapplyupdate()`、`searchscan()`、`searchapplyvieweffect()`。目标是减少 `searchset()` 直接理解的时序知识，不迁移 `query` ownership。

## Acceptance criteria

- [x] `searchset()` 不再原地展开 query 替换的完整时序
- [x] 新 helper 只承载时序，不接管 `query` 的 `malloc/free` ownership
- [x] `zig build abi-check`、`zig build test`、`zig build` 通过

## Blocked by

- `.scratch/search-query-seam/issues/01-design-query-buffer-seam.md`
