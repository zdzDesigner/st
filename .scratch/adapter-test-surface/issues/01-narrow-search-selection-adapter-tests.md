Title: 收窄 Search/Selection adapter tests
Status: completed

## What to do

把 Search/Selection adapter tests 收窄为 smoke tests，只验证 extern/domain/extern 转换不丢关键字段；领域行为继续由内部 module tests 覆盖。

## Scope

- `st_search.zig`
- `st_selection.zig`

## Acceptance criteria

- [x] adapter tests 不再重复覆盖完整 domain behaviour
- [x] domain tests 仍保留行为断言
- [x] ABI smoke coverage 仍存在
