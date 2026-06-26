Title: 为 input transaction seam 增加测试
Status: completed

## What to build

围绕 input mutation seam 增加测试，覆盖 grow、原地插入、删除、clear-input 和 `searchset()` 触发条件。目标是为后续是否迁 input ownership 提供足够的行为护栏。

## Acceptance criteria

- [x] 覆盖至少一组 grow / in-place insert / delete / clear-input 事务行为
- [x] 覆盖 `searchset()` 触发与不触发的条件边界
- [x] 新测试不要求迁移 `search.input` ownership

## Blocked by

- `.scratch/search-input-ownership/issues/02-extract-input-mutation-transaction.md`
