Title: 为 SearchScalarState 增加状态边界测试
Status: completed

## What to build

补一组围绕 `SearchScalarState` 的边界测试，验证 snapshot 读取、update 写回以及若干关键调用点在消费 `SearchScalarState` 后行为不变。目标是让后续更深的 ownership 迁移可以基于这组测试安全演进。

## Acceptance criteria

- [x] 覆盖 `SearchScalarState` 与 `ZigSearchSnapshot` / `ZigSearchStateUpdate` 的往返映射
- [x] 覆盖至少一组 `searchnext/searchprev/searchjump/searchscan` 的共享状态读取行为
- [x] 新测试不依赖迁移 `query/input/matches` 指针所有权

## Blocked by

- `.scratch/search-scalar-state-ownership/issues/01-expand-searchscalarstate-adoption.md`
