Title: draw region effect reuse
Status: ready-for-agent
Progress: completed

## Goal

让 `drawregion()` 不再维护独立的 region step switch，而是复用现有 `platformapplydraweffect()` 作为唯一 draw-region effect executor，继续压薄 `st.c` 的 draw 路径重复逻辑。

## Scope

- `st.c:drawregion()`
- `st.c:platformapplydraweffect()`
- 相关 `st_cursor.zig` draw region / frame tests

## Boundary

- 只处理 `Dirty + Cursor + Draw` seam 内的重复 effect 执行逻辑。
- 不改变 `draw()` 顶层 effect 顺序。
- 不改变 `st_drawregiontransaction(...)` 的 ABI 与 step 协议。
- 不迁移 X11 / PTY / clipboard / IO ownership。

## Dependencies

- `01-drawregion-transaction-executor`
- `02-frame-executor-coarse-plan`
- `03-frame-regression-coverage`

## Blocked by

- 无

## Acceptance criteria

- `drawregion()` 不再手写解释 `REGION_DRAW_LINE` / `REGION_CLEAR_DIRTY` / `REGION_ADVANCE`。
- region step 统一通过 `platformapplydraweffect()` 消费。
- 对未知或越界 step 仍保持 fail-fast。
- `zig build abi-check`、`zig build test`、`zig build` 通过。

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`
- `timeout 5 ./zig-out/bin/st`

## Comments

- 2026-07-03 Observe: `draw()` 已切到 `platformapplyeffects(..., PLATFORM_CONTEXT_DRAW)`，但 `drawregion()` 仍在 `st.c:2891-2922` 维护第二套 region step switch，而 `st.c:2253-2292` 的 `platformapplydraweffect()` 已有对应的 `REGION_DRAW_LINE` / `REGION_CLEAR_DIRTY` / `REGION_ADVANCE` 分支。该重复逻辑位于同一 draw seam，适合做下一刀收口。
- 2026-07-03 Draft/Review round 1: `coder` 先把 `drawregion()` 改成转发 `tx.steps` 到 `platformapplydraweffect()`；`code-reviewer` 预审指出这样会丢失原 `drawregion()` 的 fail-fast 边界检查，并且 region context 缺少 `y1/y2` 与 `frame=NULL` 防御，属于阻塞问题。
- 2026-07-03 Draft/Review round 2: `coder` 在 `PlatformDrawContext` 新增 `.y1/.y2`，并在 `draw()` / `drawregion()` 的 context 初始化里全部填充；`platformapplydraweffect()` 为 `DRAW_CURSOR` / `FINISH_DRAW` 加入 `frame==NULL` fail-fast，为 `REGION_CLEAR_DIRTY` / `REGION_DRAW_LINE` / `REGION_ADVANCE` 恢复与旧 `drawregion()` 等价的边界检查；`drawregion()` 最终只保留 transaction + context + 转发循环。
- 2026-07-03 Review result: `code-reviewer` 最终复审无 critical/high，确认 issue 04 通过。剩余项仅是非阻塞测试细化，例如补 `platformapplydraweffect()` 边界触发路径测试和 `DRAW_REGION -> drawregion() -> REGION_*` 的集成等价测试。
- 2026-07-03 Validation: `zig build abi-check`、`zig build test`、`zig build`、`timeout 5 ./zig-out/bin/st` 通过。实现完成。
