Title: history read snapshot
Status: ready-for-agent
Progress: completed

## Goal

把 `tlinehist()` / `tlineviewport()` 所依赖的 history/viewport 读取事实收口成显式 snapshot seam，避免这两个核心入口继续直接散读 `term.scr` / `term.histi` / `term.hist` / `term.line`。

## Scope

- `st.c:tlinehist()`
- `st.c:tlineviewport()`
- 与之最小相关的 Zig history line read plan/snapshot

## Boundary

- 先只收口读模型，不改 pointer ownership。
- 不替换所有 `TLINE(...)` 调用点。
- 不改 `externalpipe()` / `search` / `selection` 的高层行为。

## Dependencies

- `docs/zig-architecture.md`
- `docs/architecture-flow.md`
- `st.c:443-453`

## Blocked by

- 无

## Acceptance criteria

- `tlinehist()` / `tlineviewport()` 不再在函数体内直接展开所有 history/viewport 标量事实。
- 新边界能显式表达“读历史行还是当前屏幕行”的判定输入。
- `zig build abi-check`、`zig build test`、`zig build` 通过。

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`
- `timeout 5 ./zig-out/bin/st`

## Comments

- 2026-07-03 Observe: 当前 `tlinehist()` / `tlineviewport()` 是 `Line/History owner` 最集中的读入口，且直接掌握 `term.hist` / `term.line` / `term.scr` / `term.histi` 的组合读取知识。第一刀先把这里的读事实显式化，收益最高、范围最小。
- 2026-07-03 Draft/Review: 新增 `ZigTermLineReadSnap` / `ZigTermLineReadPlan` 与 `st_termlinereadplan(...)`，用 `kind` 区分 `viewport_y` 和 `flat_history_y` 两种读坐标系。`tlinehist()` / `tlineviewport()` 现在都先组装 snapshot，再由 Zig 返回 `{hist,index}`，C 侧仅保留 `term.hist[]` / `term.line[]` 指针选择，不迁 ownership。
- 2026-07-03 Fixes: 初版测试暴露 `History.index` 预期值错误，并且旧 `st_tlinehistplan` export 未从 ABI 移除。已修正测试预期，将旧 export 降级为私有测试 helper，并从 `st_zig.h` 删除残留声明与死掉的 `ZigHistoryLinePlan`。
- 2026-07-03 Review result: `code-reviewer` 复审无 critical/high/medium，确认只做读模型显式化，没有偷渡 pointer ownership 或高层行为改动。
- 2026-07-03 Validation: `zig build abi-check`、`zig build test`、`zig build`、`timeout 5 ./zig-out/bin/st` 全部通过。实现完成。
