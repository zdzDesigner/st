Title: 为 searchset 双阶段 contract 增加测试
Status: completed

## What to build

围绕 `searchset()` 的两阶段 contract 补测试：第一阶段只拿 `alloc_len`，第二阶段用 decoded `qlen` 获取最终 `SearchStateUpdate` / `SearchEffectPlan`。目标是为后续 query seam 重构提供测试护栏。

## Acceptance criteria

- [x] 覆盖 alloc 阶段与 decoded apply 阶段的状态/副作用输出
- [x] 测试明确区分 UTF-8 字节长度和 decoded `qlen`
- [x] 新测试不要求迁移 `query` ownership

## Blocked by

- `.scratch/search-query-seam/issues/02-extract-query-replace-transaction.md`
