Title: owner map document
Status: ready-for-agent
Progress: completed

## Goal

新增 `docs/c-responsibility-map.md`，把 `st.c` / `x.c` 主流程函数按 owner 分类，并明确每个函数的迁移风险和前置验证。

## Scope

- 覆盖 owner：Input、EscapeMachine、TerminalState、Screen、History、Selection、Search、Renderer、Platform。
- 覆盖主流程函数、高风险 seam、已迁 Zig plan/adapter 的 C 消费边界。
- 只新增文档和本地 issue 记录。

## Boundary

- 不改行为代码。
- 不新建 ABI。
- 不把文档描述当作 ownership 已迁移的证据。

## Dependencies

- `docs/terminal-effect-ordering.md`
- `docs/zig-architecture.md`
- `docs/architecture-flow.md`
- `docs/reports/20260702-copy-delete-root-cause.md`

## Blocked by

- 无。

## Acceptance criteria

- `docs/c-responsibility-map.md` 存在。
- 文档引用四类 ordering 护栏。
- 每个 owner 至少列出关键函数，并包含：当前文件、owner、是否持有状态、是否执行副作用、是否可迁 Zig、风险等级、前置验证。
- Review 无 critical/high 问题。
- 文档改动不会引入构建或 ABI 回归。

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`

## Comments

- 2026-07-03 Observe: 已读取 `/tmp/st-handoff-20260703-173740.md`、`AGENTS.md`、`README.md`、`build.zig`、`docs/zig-architecture.md`、`docs/architecture-flow.md`、`docs/terminal-effect-ordering.md`、`docs/reports/20260702-copy-delete-root-cause.md`、`st.h`、`win.h`、`st_zig.h`。Zig 版本为 `0.16.0`。
- 2026-07-03 Decompose: 当前 feature 只有一个 blocking 切片：新增 C responsibility map 文档。后续 owner 迁移不在本任务范围内。
- 2026-07-03 Draft: `coder` 已落盘 `docs/c-responsibility-map.md`，仅新增文档，未修改行为代码。
- 2026-07-03 Review round 1: `code-reviewer` 未发现 critical，但指出 4 个 high：`swapscreen()`/`setdirt()` 函数名与行号错误、`searchset()` 行号错误、`getsel()` 行号错误；另有中低风险建议包括 `tsetattr` 重复、`selectioncopyline()` 指向声明、`selsnap()` 描述不准。
- 2026-07-03 Execute round 1: 已修正为 `tswapscreen()` `st.c:1569` 且标记不可迁、`tsetdirt()` `st.c:1499`、`searchset()` `st.c:954`、`getsel()` `st.c:1148`、`selectioncopyline()` `st.c:1185`、`selsnappoint()` `st.c:1075`，并将 Screen 表中的 `tsetattr` 改为交叉引用。
- 2026-07-03 Review round 2: `code-reviewer` 复审确认上一轮 4 个 high 和 3 个建议均已修复，并抽样核对约 60 个函数行号；无 critical/high/medium/low，review 通过。
- 2026-07-03 Validation: `zig build abi-check`、`zig build test`、`zig build` 均通过。实际修改文件：`docs/c-responsibility-map.md`、`.scratch/c-responsibility-map/PRD.md`、`.scratch/c-responsibility-map/issues/01-owner-map-document.md`。未新增后续 blocking 任务。implementation complete。
