# Putc Atomic Commit Owner

## Goal

围绕 `tputc()` 图形字符写入尾段，先收口“单次 glyph 写入提交”的 C-side commit 边界，固定 `st_tputcwrite(...) -> dirty -> advance/wrapnext` 的原子提交顺序，为后续更深的 input/term state ownership 做准备。

## Evidence

- `docs/reports/20260702-copy-delete-root-cause.md:11-13` 已确认根因在 `tputc()` 图形写入尾段的状态提交时机，而不在 draw/scroll/resize。
- `docs/reports/20260702-copy-delete-root-cause.md:19-24` 明确旧稳定语义是一个不可拆的原子动作：写 glyph、根据 `write.advance` 前进、当前行标 dirty、必要时设置 `CURSOR_WRAPNEXT`。
- `docs/reports/20260702-copy-delete-root-cause.md:76-83` 明确当前稳定实现保留 `st_tputcwrite(...)`，并把 dirty 与 `CURSOR_WRAPNEXT` 提交恢复到旧语义。
- `docs/zig-architecture.md:76-78` 和 `docs/architecture-flow.md:240` 明确禁止再次把 dirty / cursor-state 提交机械拆成 `ZigPutcStepPlan` 独立字段消费。
- `st.c:2791-2814` 当前仍在 `tputc()` 尾段内联执行 `st_tputcwrite(...)` 后的 dirty / move / wrapnext 提交协议，尚未形成单一命名边界。

## Non-goals

- 本 feature 不把 dirty / `CURSOR_WRAPNEXT` 重新迁回 Zig planner 字段。
- 本 feature 不迁移 `term.line` ownership。
- 本 feature 不改动 STR/control/ESC route。

## Task Queue

1. `01-extract-putc-commit-helper`
2. `02-putc-commit-regression-coverage`
3. `03-c-commit-harness`

## Status

- `01-extract-putc-commit-helper`: completed
- `02-putc-commit-regression-coverage`: completed
- `03-c-commit-harness`: completed

## Final Validation

- `zig build abi-check`
- `zig build test`
- `zig build`
- `timeout 5 ./zig-out/bin/st`

以上命令已在本轮全部通过。
