Title: frame regression coverage
Status: ready-for-agent
Progress: completed

## Goal

补 frame 级回归覆盖，固定 `Dirty + Cursor + Draw` 时序语义。

## Scope

- `st_cursor.zig` tests
- 必要时补最小启动冒烟验证说明

## Boundary

- 重点覆盖 dirty 清理顺序、cursor draw gate、imspot gate、search scan gate。

## Dependencies

- `01-drawregion-transaction-executor`
- `02-frame-executor-coarse-plan`

## Blocked by

- `02-frame-executor-coarse-plan`

## Acceptance criteria

- 新增测试能锁定 frame transaction 与 frame orchestration 的关键顺序。

## Validation

- `zig build test`
- `zig build`
- `timeout 5 ./zig-out/bin/st`

## Comments

- 2026-07-02 Observe: `01` 与 `02` 已完成并通过构建/启动验证。当前缺口集中在 frame effect 顺序与 gate 组合测试。
- 2026-07-02 Draft/Review round 1: `coder` 先补了 4 组 frame tests；`code-reviewer` 预审指出仍缺 `imspot_active(ocy)`、transaction 单行 3-step、无 search 但有 dirty 的顺序断言，旧 review 结果基于前一版测试快照。
- 2026-07-02 Draft/Review round 2: `coder` 补齐 `imspot_active triggers on ocx change only`、`imspot_active triggers on ocy change only`、`draw region transaction single dirty row emits full 3-step order`、`frame no search with dirty starts with draw_region`。`code-reviewer` 最终复审结论：无阻塞问题，通过。
- 2026-07-02 Validation: `zig build test`、`zig build`、`timeout 5 ./zig-out/bin/st` 通过。剩余缺口仅为非阻塞测试细化（如显式断言无 `IME_SPOT` 的负路径）。
