# C Responsibility Map

## Goal

基于 Terminal Effect Ordering 护栏，建立 `st.c` / `x.c` owner 责任地图，为后续把 C 收缩为 platform shim、把 terminal 领域状态逐步迁到 Zig owner struct 提供可审查边界。

## Evidence

- `/tmp/st-handoff-20260703-173740.md:138` 建议下一步创建 `docs/c-responsibility-map.md`。
- `docs/terminal-effect-ordering.md:11`、`docs/terminal-effect-ordering.md:22`、`docs/terminal-effect-ordering.md:41`、`docs/terminal-effect-ordering.md:58` 定义四类迁移护栏。
- `docs/zig-architecture.md:76`、`docs/zig-architecture.md:77` 要求显示链路迁移前检查 effect ordering。
- `docs/architecture-flow.md:225` 至 `docs/architecture-flow.md:232` 定义 owner project 和 platform shim 迁移顺序。

## Non-goals

- 不修改 C/Zig 行为代码。
- 不迁移任何 owner ownership。
- 不穷尽每个静态 helper，只覆盖主流程函数和高风险 seam。

## Task Queue

1. `01-owner-map-document`

## Status

- `01-owner-map-document`: completed

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`

以上命令已在 `01-owner-map-document` 完成后通过。
