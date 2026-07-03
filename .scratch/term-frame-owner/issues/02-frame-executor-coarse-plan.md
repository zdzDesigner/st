Title: frame executor coarse plan
Status: ready-for-agent
Progress: completed

## Goal

把 `draw()` 的 frame orchestration 收口为更粗粒度的 frame executor，减少 C 对 draw 顺序的手写控制。

## Scope

- `st.c:draw()`
- `st_cursor.zig:st_drawexecplan(...)`
- frame platform effect ordering

## Boundary

- 基于任务 01 的 transaction executor 继续推进。
- 不改变平台资源 ownership。

## Dependencies

- `01-drawregion-transaction-executor`

## Blocked by

- `01-drawregion-transaction-executor`

## Acceptance criteria

- `draw()` 主要消费 frame plan / effect list，而不是分散编排 draw region、cursor、finish、imspot。
- 行为保持与当前稳定语义一致。

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`
- `timeout 5 ./zig-out/bin/st`

## Comments

- 2026-07-02 Observe: `01-drawregion-transaction-executor` 已完成并通过 `zig build abi-check`、`zig build test`、`zig build`。当前证据显示 `st.c:2253-2292` 已具备 `PLATFORM_CONTEXT_DRAW` effect executor，`st.c:2925-2938` 仍手写 frame orchestration，适合做下一刀粗粒度收口。
- 2026-07-02 Draft/Review round 1: `coder` 将 `draw()` 改为直接消费 `frame.platform`，复用既有 `platformapplyeffects(..., PLATFORM_CONTEXT_DRAW)`；`code-reviewer` 预审提示需要核实 `x1/x2` 初始化和 `DRAW_REGION(effect.arg)` 是否与旧扫描起点等价。主代理复核实际代码后确认 `PlatformDrawContext` 已显式传入 `.x1 = 0, .x2 = term.col`，并追加把 `DRAW_REGION` 调用参数改成读取 `context->payload.draw.x1/x2`，消除双来源风险。
- 2026-07-02 Review result: 基于实际文件的最终复审无 critical/high，确认 `drawregion(0, region.y, ...)` 与旧 `drawregion(0, 0, ...)` 在当前首 dirty 行语义下等价；剩余缺口仅为交互手测细化。
- 2026-07-02 Validation: `zig build abi-check`、`zig build test`、`zig build`、`timeout 5 ./zig-out/bin/st` 全部通过。实现完成。
