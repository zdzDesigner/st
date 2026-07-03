Title: selection ownership reopen check
Status: ready-for-agent
Progress: completed

## Goal

在 `docs/terminal-effect-ordering.md` 护栏下复查 Selection owner 是否具备重新打开 ownership 迁移的条件。

## Scope

- `selstart()` / `selextend()` / `selnormalize()` / `selsnappoint()`
- `selectionapplystate()` / `selectionapplybounds()` / `selectionapplyresult()` / `selectionapplyscrollresult()`
- `getsel()` / `selectioncopyline()`

## Boundary

- 不迁移 clipboard、malloc、UTF-8 output buffer ownership。
- 不迁移 C 侧 `TLINE(...)` glyph 读取。

## Dependencies

- `01-owner-roadmap-freeze`

## Blocked by

- `.scratch/terminal-effect-owner-roadmap/issues/01-owner-roadmap-freeze.md`

## Acceptance criteria

- [x] 明确 selection 当前 completed seam 是否仍自洽。
- [x] 明确是否存在只扩展 snapshot/update 的安全切片。
- [x] 若无法继续迁移，记录 blocker 和恢复条件。

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`

## Comments

- 2026-07-03 Frame: 本切片按 `docs/terminal-effect-ordering.md` 的 selection 状态决策、selection scroll result apply、line/history fact reading、clipboard/title/resource ownership 护栏复查 Selection owner。
- 2026-07-03 Evidence: `st.c:473` 至 `st.c:566` 显示 `selstart()`、`selextend()`、`selnormalize()`、`selected()` 已通过 `ZigSelectionSnapshot -> ZigSelectionStateResult / ZigSelectionStateUpdate` 消费 Zig 决策，C 只执行 `sel` 字段写回和 dirty effect。
- 2026-07-03 Evidence: `st_selection.zig:231` 至 `st_selection.zig:280` 的 `SelectionModel` 已承载 start、extend、scroll、normalize、selected、getSelPlan 领域决策；`st_selection.zig:779` 至 `st_selection.zig:887` 已提供 C ABI adapter。
- 2026-07-03 Evidence: `st.c:1075` 至 `st.c:1145` 显示 `selsnappoint()` 的 word/line snap loop 已由 Zig iterator/step 控制，但 C 仍按 Zig request 读取 `TLINE(...)`、delimiter、line length、wrap glyph mode 等事实。
- 2026-07-03 Evidence: `st.c:1119` 至 `st.c:1143` 显示 line snap 同样由 `st_selsnaplinex(...)` / `st_selsnaplinestep(...)` 控制 stop/move，C 只读取 wrap mode 事实。
- 2026-07-03 Evidence: `st.c:1148` 至 `st.c:1198` 显示 `getsel()` 已由 `st_selectionextracttransaction(...)` 和 `st_getselexecplan(...)` 规划 allocation/copy/nul 与行输出范围，但 C 仍执行 `xmalloc()`、`TLINE(...)` glyph 读取、`utf8encode()` 和最终 selection 文本构造。
- 2026-07-03 Evidence: `.scratch/selection-ownership-review/issues/01-boundary-review.md:10` 已给出相同结论：Selection state 已使用 snapshot/update/effect，剩余是 `TLINE(...)` fact reading、malloc、UTF-8 encoding 和 clipboard output。
- 2026-07-03 Decision: 不重开 Selection ownership 迁移。当前 seam 已通过 deletion test：删除 `SelectionModel` / `SnapWordIterator` 会把 selection 状态规则、snap 停止规则、getsel 行范围规则重新分散回 C 调用点；但剩余 C 代码是 reader/effect/resource executor，不是重复领域规则。
- 2026-07-03 Reopen condition: 只有当新 selection 功能在 C 里新增或复制 selection 语义规则，或新增需要 Zig 决策的 selection 坐标变换，而不是事实读取或资源输出时，才新增 AFK 实现切片。当前不新增实现 issue。
- 2026-07-03 Validation target: 本切片为 boundary review，验证命令使用 `zig build abi-check`、`zig build test`、`zig build`。
- 2026-07-03 Review: `code-reviewer` 未发现 critical/high，确认 seam 自洽和不可迁 ownership 判断正确；已补充 line snap 证据和 reopen condition。
