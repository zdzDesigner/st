# Term Frame Owner

## Goal

把 `TermState Owner` 的首个可执行切片落到 `Dirty + Cursor + Draw` 主链，先收口 draw 读模型和 dirty region 执行事务，再逐步压薄 `st.c` 的显示主循环。

## Evidence

- `docs/zig-architecture.md:26-28` 已把 `TermState owner` 定义为阶段 3，要求用统一 state update / effect plan 收口 `term` 标量与 draw effect。
- `docs/zig-architecture.md:76-78` 明确指出 draw/graphic putc 对时序敏感，不能把字段等价当成行为等价。
- `docs/architecture-flow.md:190-199` 当前 draw 主流程是 `ZigTermFrameSnapshot -> DrawExecPlan -> searchscan -> drawregion -> xdrawcursor -> xximspot`。
- `docs/architecture-flow.md:237` 明确当前稳定实现仍保留 `searchscan -> drawregion -> xdrawcursor -> xfinishdraw` 的旧消费语义，但允许继续沿 `Dirty + Cursor + Draw` owner seam 扩展。
- `st.c:2891-2931` 证明 `drawregion()` 仍在 C 里手写 dirty loop，而 `draw()` 仍自己编排 frame 顺序。
- `st_cursor.zig:334-364` 已有 `st_drawexecplan(...)` 与未导出的 `st_drawregiontransaction(...)`，说明 dirty region transaction seam 已具备实现基础。

## Non-goals

- 本 feature 不迁移 X11 / PTY / clipboard / IO ownership。
- 本 feature 不在同一轮里重做 resize 和 graphic putc 行为。
- 本 feature 不直接重排 `searchscan -> drawregion -> xdrawcursor -> xfinishdraw` 的全流程顺序，除非已有 transaction 化切片稳定。

## Task Queue

1. `01-drawregion-transaction-executor`
2. `02-frame-executor-coarse-plan`
3. `03-frame-regression-coverage`

## Status

- `01-drawregion-transaction-executor`: completed
- `02-frame-executor-coarse-plan`: completed
- `03-frame-regression-coverage`: completed

## Final Validation

- `zig build abi-check`
- `zig build test`
- `zig build`
- `timeout 5 ./zig-out/bin/st`

以上命令已在本轮全部通过。
