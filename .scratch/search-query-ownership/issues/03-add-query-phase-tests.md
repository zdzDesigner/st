Title: 为 query phase seam 增加测试
Status: completed

## What to build

围绕 query alloc/apply 两阶段 seam 增加测试，覆盖 alloc 长度、decoded `qlen`、clear/apply effect 和最终状态边界。目标是为后续是否迁 query ownership 提供测试护栏。

## Acceptance criteria

- [x] 覆盖 alloc phase 与 apply phase 的边界行为
- [x] 覆盖 `alloc_len`、decoded `qlen` 和 `clear_query` / `refresh_search` / `jump` 的组合
- [x] 新测试不要求迁移 `search.query` ownership

## Blocked by

- `.scratch/search-query-ownership/issues/02-extract-query-alloc-phase.md`
