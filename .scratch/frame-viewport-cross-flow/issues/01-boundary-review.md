Title: 复查 Frame/Viewport cross-flow consolidation
Status: completed

## Scope

- `st.c:tresize()` / `tsetdirt()` / `draw()`
- `st_state.zig:st_tresizeexecplan()`
- `st_cursor.zig:st_drawexecplan()` / `st_drawregionplan()`

## Findings

- Resize 已经通过 `ZigResizeExecPlan` 返回 slide/free、container resize、history resize、line resize、tabs 和 clear region 计划，C 侧主要执行资源和内存副作用。
- Draw 本轮新增 `ZigDrawExecPlan`，已把 frame gate 和首个 dirty region 查询合并到更粗粒度的 draw plan。
- `tsetdirt()` 已拆成 `st_tsetdirtrange()` 的范围决策和 `termapplydirtyrange()` 的 C 状态写入 effect。
- 当前还没有三者共享的重复 contract；强行引入统一 frame/viewport seam 会把已有清晰 plan 合成更宽 interface。

## Decision

- 当前不实现新的 frame/viewport cross-flow module。
- 保持 resize、dirty、draw 三条 seam 各自独立。
- 后续只有在 `draw` 与 `term` 主状态迁移继续推进后，出现重复 frame snapshot/update 字段时再重开。

## Conclusion

Candidate 15 当前作为复查型 candidate 关闭。它不通过 deepening test：新 seam 的 interface 会变宽，但不会明显减少 C 中的新决策知识。
