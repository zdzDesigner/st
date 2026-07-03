Title: extract putc commit helper
Status: ready-for-agent
Progress: completed

## Goal

把 `tputc()` 图形字符写入尾段的提交协议抽成单一 C-side helper，固定 `st_tputcwrite(...) -> tsetdirt(...) -> move/wrapnext` 的原子顺序，避免这段协议继续散落在 `tputc()` 主体里。

## Scope

- `st.c:tputc()`
- 新的 C-side helper（仍在 `st.c`）
- 与 `ZigPutcWriteResult` 消费相关的最小测试

## Boundary

- 只抽出 commit helper，不改变提交顺序。
- 不新增新的 Zig ABI。
- 不把 dirty / `CURSOR_WRAPNEXT` 重新拆回 planner 字段消费。
- 不改 `st_tputcwrite(...)` 写 glyph 逻辑本身。

## Dependencies

- `docs/reports/20260702-copy-delete-root-cause.md`
- `st.c:2791-2814`
- `st_setchar.zig:18-23`

## Blocked by

- 无

## Acceptance criteria

- `tputc()` 主体不再内联展开完整的 `write.advance` 提交协议。
- 提交协议集中在单一 helper，顺序仍是 `st_tputcwrite(...)` 返回后立即 dirty，再 move/wrapnext。
- `zig build abi-check`、`zig build test`、`zig build` 通过。

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`
- `timeout 5 ./zig-out/bin/st`

## Comments

- 2026-07-03 Observe: `docs/reports/20260702-copy-delete-root-cause.md` 已证明 graphic write commit 是当前最接近真实风险中心的边界；`st.c:2791-2814` 仍把 `st_tputcwrite(...)` 后的 dirty / move / wrapnext 提交协议内联在 `tputc()` 尾段。该切片先把协议命名并集中，避免未来再被无意拆散。
- 2026-07-03 Draft/Review: `coder` 将提交协议抽成 `st.c` 内部 `static void tcommitputcwrite(ZigPutcWriteResult, int, Rune)`，保持顺序 `tsetdirt(y, y) -> term.lastc = u -> move/wrapnext`；`code-reviewer` 复审确认最关键硬约束已满足：helper 保持在 C 内，未跨 Zig 边界，也未重新拆回 planner/executor 两层。
- 2026-07-03 Validation: `zig build abi-check`、`zig build test`、`zig build`、`timeout 5 ./zig-out/bin/st` 通过。实现完成。
