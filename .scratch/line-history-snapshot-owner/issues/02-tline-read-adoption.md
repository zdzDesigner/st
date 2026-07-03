Title: tline read adoption
Status: ready-for-agent
Progress: completed

## Goal

在 `history read snapshot` 稳定后，把更多 `TLINE(...)` / history line 读取点切到统一 seam。

## Scope

- `externalpipe()`
- `search` / `selection` / draw 的后续读取点

## Boundary

- 只扩读模型采用，不引入 ownership 迁移。

## Dependencies

- `01-history-read-snapshot`

## Blocked by

- `01-history-read-snapshot`

## Acceptance criteria

- 新增调用点通过统一 seam 获取 line/history 事实。

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`
- `timeout 5 ./zig-out/bin/st`

## Comments

- 待 `01-history-read-snapshot` 完成后推进。
- 2026-07-03 Observe: `01-history-read-snapshot` 已完成并通过全局验证。当前 `externalpipe()` 已通过 `tlinehist()` 间接采用新 seam；`searchhistline(int scr)` 仍直接调用 `term.hist[st_historyringindex(term.histi, scr, HISTSIZE)]`。本轮将 `02` 收敛为第一刀：只让 `searchhistline()` 采用统一 `ZigTermLineReadSnap -> st_termlinereadplan(...)` seam，不触碰 visible scan、selection 或 draw 调用点。
- 2026-07-03 Draft/Review round 1: 初版把 `searchhistline(scr)` 误接到 `ST_ZIG_TERM_LINE_READ_HIST`，`code-reviewer` 指出这是坐标系错误：`searchhistline` 的 `scr` 是 ring offset，不是平铺历史行号。该轮 review 拒绝直接替换方案。
- 2026-07-03 Draft/Review round 2: 新增 `ST_ZIG_TERM_LINE_READ_HIST_RING` / `.hist_ring`，用 `historyIndex(histi, scr, histsize)` 表达 ring offset 语义；`searchhistline()` 改用 `HIST_RING`。补充 Zig 单测覆盖 `hist_ring` 与 export round-trip。
- 2026-07-03 Review result: `code-reviewer` 复审确认新实现与旧 `term.hist[historyIndex(term.histi, scr, HISTSIZE)]` 完全等价，无 critical/high/medium。
- 2026-07-03 Validation: `zig build abi-check`、`zig build test`、`zig build`、`timeout 5 ./zig-out/bin/st` 全部通过。实现完成。
- 2026-07-03 Regression fix: `tlinehist()` 不能采用 `HIST_RING`，因为 `externalpipe()` 传入的是平铺历史/屏幕行号，首行必须映射到 `historyLine()` 的 hist index 0；`HIST_RING` 只适用于 `searchhistline(scr)` 的 ring offset 坐标。修复为 `ST_ZIG_TERM_LINE_READ_HIST`，并新增 external pipe row order 回归测试。
