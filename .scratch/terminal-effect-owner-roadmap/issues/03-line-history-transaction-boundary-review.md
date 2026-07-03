Title: line history transaction boundary review
Status: ready-for-agent
Progress: completed

## Goal

复查 Line/History owner 的 pointer transaction、history ring 和 scroll/resize 边界，确认哪些只能保持 C executor，哪些可以继续收口为 snapshot/update/effect plan。

## Scope

- `tlinehist()` / `tlineviewport()` / `searchhistline()`
- `tscrollup()` / `tscrolldown()` / `tapplyscrollplan()`
- `linepointer*()` helper family
- `tresize()` / `st_tresizeexecplan()`

## Boundary

- 不迁移 `term.line`、`term.alt`、`term.hist` 指针 ownership。
- 不重排 scroll transaction 或 resize transaction。

## Dependencies

- `01-owner-roadmap-freeze`

## Blocked by

- `.scratch/terminal-effect-owner-roadmap/issues/01-owner-roadmap-freeze.md`

## Acceptance criteria

- [x] 明确 Line/History 后续是否还有安全实现切片。
- [x] 如果只有文档/测试缺口，新增对应 issue 而不是强行迁移 ownership。
- [x] 记录 scroll/resize 的验证要求。

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`

## Comments

- 2026-07-03 Frame: 本切片按 `docs/terminal-effect-ordering.md` 的 scroll transaction、resize transaction、line/history 坐标决策和 C executor ownership 护栏复查 Line/History owner。
- 2026-07-03 Evidence: `.scratch/line-history-snapshot-owner/PRD.md:23` 至 `.scratch/line-history-snapshot-owner/PRD.md:29` 显示 line/history 读模型两项切片均已 completed；`st.c:443` 至 `st.c:470` 当前 `tlinehist()` / `tlineviewport()` 已通过 `ZigTermLineReadSnap -> st_termlinereadplan(...)` 获取 `{hist,index}` 再由 C 读取 `term.hist[]` 或 `term.line[]`。
- 2026-07-03 Evidence: `st.c:1604` 至 `st.c:1645` 显示 scroll transaction 已由 `st_tscrollplan(...)` 返回 `ZigScrollPlan`，但 C 仍按旧语义执行 history state update、`tclearregion()`、`tsetdirt()`、line pointer swap loop 和 `selscroll()`。
- 2026-07-03 Evidence: `st_edit.zig:117` 至 `st_edit.zig:157` 已把 scroll 的 history swap、scrollback update、clear/dirty、line swap loop、selection scroll 顺序表达为 step list；`st_edit.zig:239` 至 `st_edit.zig:296` 有 scroll up/down ordering 单测。
- 2026-07-03 Evidence: `st.c:1647` 至 `st.c:1689` 的 `linepointer*()` helper 直接读写 `term.line`、`term.alt`、`term.hist` 并执行 `free()`、`memmove()`、`xrealloc()`、`xmalloc()`；命中 `docs/terminal-effect-ordering.md:64` 和 `docs/terminal-effect-ordering.md:69` 的只能留 C executor。
- 2026-07-03 Evidence: `st.c:2891` 至 `st.c:2950` 显示 resize transaction 仍在 C 执行 slide/free/memmove、container realloc、history row realloc/fill、row realloc/alloc、tabs、dimension writeback、clear/swap/load cursor；`st_state.zig:231` 至 `st_state.zig:259` 只返回 `ZigResizeExecPlan` 范围和 ordered steps。
- 2026-07-03 Decision: 当前 Line/History 的安全收益边界已到读模型和 ordered plan。继续迁 pointer ownership 或 resize/scroll executor 会触碰 line/history 资源 ownership 和显示时序放大器，违反 `docs/terminal-effect-ordering.md:32`、`docs/terminal-effect-ordering.md:33`、`docs/terminal-effect-ordering.md:64`。
- 2026-07-03 Follow-up: 不新增实现 issue。后续只有在补足 scroll/resize 交互回归测试，或明确要迁 `term.line` / `term.hist` ownership 的 deliberate project 时，才允许重新打开实现切片。
- 2026-07-03 Validation target: 本切片为 boundary review，验证命令使用 `zig build abi-check`、`zig build test`、`zig build`。
- 2026-07-03 Review: `code-reviewer` 未发现 critical/high/medium，确认 line/history 读模型、scroll transaction、resize transaction 和 C ownership 判断正确。低项补记：`kscrollup()` / `kscrolldown()` 也已通过 `ZigKScrollPlan` 驱动 history state update + `selscroll` + `tfulldirt`，但不涉及 line pointer swap；resize ordered steps 不覆盖 `tsetscroll()`、`tmoveto()`、双屏 clear/swap/load cursor 子步骤，这些仍属于 C executor 顺序护栏。
