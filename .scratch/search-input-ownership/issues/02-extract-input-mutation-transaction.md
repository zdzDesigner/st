Title: 抽出 Search input mutation transaction seam
Status: completed

## What to build

把 `searchinput()`、`searchdelete()`、`searchapplystate()` 里与 input 变更直接相关的执行时序收口到单一 helper，集中处理 `realloc_input`、`memmove/memcpy`、`'\0'` 写入和最终 `searchset()` 触发。这个 slice 不迁 `search.input` ownership。

## Acceptance criteria

- [x] input 变更关键时序不再散落在多个 C 调用点
- [x] 新 seam 只承载 transaction 顺序，不接管 `search.input` 指针生命周期
- [x] `zig build abi-check`、`zig build test`、`zig build` 通过

## Blocked by

- `.scratch/search-input-ownership/issues/01-design-input-ownership-seam.md`
