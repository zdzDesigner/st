Title: escape machine boundary review
Status: ready-for-agent
Progress: completed

## Goal

复查 EscapeMachine owner 的 STR/ESC/CSI/control 边界，确认下一步是否存在安全的纯决策或 transaction 化切片。

## Scope

- `tcontrolcode()` / `inputapplycontrolplan()`
- `csiparse()` / `csihandle()`
- `strhandle()` / `strparse()` / `strapplyplan()` / `strreset()`
- `tstrsequence()` / `eschandle()`

## Boundary

- 不迁移 heap mutation、platform effects、`csiescseq` / `strescseq` buffer ownership。
- 不重排 ESC flow、STR collection、OSC/platform effect list。

## Dependencies

- `01-owner-roadmap-freeze`

## Blocked by

- `.scratch/terminal-effect-owner-roadmap/issues/01-owner-roadmap-freeze.md`

## Acceptance criteria

- [x] 明确哪些 EscapeMachine 逻辑只是纯决策。
- [x] 明确哪些步骤必须继续由 C executor 有序执行。
- [x] 若存在实现切片，新增后续 AFK issue；若不存在，记录关闭原因。

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`

## Comments

- 2026-07-03 Frame: 本切片按 `docs/terminal-effect-ordering.md` 的 STR collection、ESC flow、OSC/platform string effects、RIS reset 护栏复查 EscapeMachine owner，不做行为代码修改。
- 2026-07-03 Evidence: `st.c:2750` 至 `st.c:2784` 显示 STR collection 已按 `ZigStrCollectTransaction` 有序执行，C 仍负责 `xrealloc`、`memcpy` 和 `strescseq` 写回；`st_setchar.zig:476` 至 `st_setchar.zig:494` 已把 grow/retry/finish/abort 表达为 transaction steps。
- 2026-07-03 Evidence: `st.c:2801` 至 `st.c:2836` 显示 ESC flow 已按 Zig 返回 action list 执行 write CSI byte、parse CSI、handle CSI、define UTF-8、define charset、DEC test、ESC handle；`st_setchar.zig:370` 至 `st_setchar.zig:416` 已承载 action ordering 的纯决策。
- 2026-07-03 Evidence: `st.c:2013` 至 `st.c:2057` 显示 `csihandle()` 已只消费 `st_csiexecplan(...)` 顶层 plan，真实 edit/cursor/mode/attr/state 副作用仍在 C executor；`st_csi.zig:206` 至 `st_csi.zig:365` 已承载 CSI 顶层分类和子 plan。
- 2026-07-03 Evidence: `st.c:2098` 至 `st.c:2203` 显示 OSC/platform string effects 由 `ZigPlatformEffectList` 有序执行；`st_strhandle.zig:112` 至 `st_strhandle.zig:150` 已承载 title/clipboard/color effect list 纯规划，C 仍持有 X11/clipboard/color 副作用。
- 2026-07-03 Decision: 当前 EscapeMachine seam 已是较深 module：小 interface 是 `ZigStrCollectTransaction`、`ZigInputEscFlowPlan`、`ZigCsiExecPlan`、`ZigStrHandlePlan` / `ZigPlatformEffectList`，implementation 集中了大量 parsing/decision/order 规则。删除这些 plan 会把复杂性重新摊回 `tputc()`、`csihandle()`、`strhandle()`，通过 deletion test。
- 2026-07-03 Boundary: 不新增实现 issue。原因是剩余复杂性主要是 C executor 必须持有的 heap mutation、CSI/STR buffer 写回、platform effects、TTY/X11/reset 副作用；继续迁会触碰 `docs/terminal-effect-ordering.md:58` 至 `docs/terminal-effect-ordering.md:74` 的只能留 C executor 区域。
- 2026-07-03 Validation target: 本切片为文档化 boundary review，验证命令使用 `zig build abi-check`、`zig build test`、`zig build`，确认未引入行为回归。
- 2026-07-03 Review: `code-reviewer` 未发现 critical/high，确认 boundary review 事实和 deletion test 结论成立；已勾选 acceptance criteria。`Status` 保持 `ready-for-agent`，因为本仓库用 `Progress: completed` 表示执行完成。
