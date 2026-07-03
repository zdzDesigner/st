Title: putc commit regression coverage
Status: ready-for-agent
Progress: completed

## Goal

补 `tputc()` atomic commit 边界的回归覆盖，锁定 dirty 与 `CURSOR_WRAPNEXT` 的提交顺序语义。

## Scope

- `st_setchar.zig` tests
- 必要时补最小启动/手测说明

## Boundary

- 只覆盖 commit 顺序语义，不引入新的 ownership 设计。

## Dependencies

- `01-extract-putc-commit-helper`

## Blocked by

- `01-extract-putc-commit-helper`

## Acceptance criteria

- 新增测试能固定 graphic write 提交语义的关键不变量。

## Validation

- `zig build test`
- `zig build`
- `timeout 5 ./zig-out/bin/st`

## Comments

- 2026-07-03 Observe: `01-extract-putc-commit-helper` 已完成，当前自动化测试只覆盖 `st_tputcwrite(...)` 的纯写入/advance 逻辑，尚未明确记录 C-side commit 协议的不变量与最小手测要求。由于当前仓库没有现成的 C 集成测试 harness，本轮先补可验证的不变量测试和回归手测说明。
- 2026-07-03 Agent: 已补 10 条不变量测试到 `st_setchar.zig`，锁定 `(advance, cursor_state_mask, cursor_state_bits)` 三元组一致性、`mark_dirty` 永为 1、`wrapnext_newline`/`overflow_newline` 互斥、以及 `st_inputstepplan` putc subplan 与独立 `st_tputcstepplan` 语义一致。同时在 C-side 不可自动覆盖的 dirty/wrapnext 提交时序追加手测 checklist。
- 2026-07-03 Review result: `code-reviewer` 复审结论为通过，无 critical/high。主代理随后补了一条直接双源交叉断言 `putcwrite 与 stepplan 三元组直接一致`，并把 hand-checklist 冗余同步到 `docs/reports/20260702-copy-delete-root-cause.md`，降低 issue 关闭后的知识流失风险。
- 2026-07-03 Validation: `zig build abi-check`、`zig build test`、`zig build`、`timeout 5 ./zig-out/bin/st` 通过。实现完成。

### 手测 Checklist（针对 copy/delete 增殖风险）

> 根因：`docs/reports/20260702-copy-delete-root-cause.md` 指出 dirty 与 CURSOR_WRAPNEXT 不在同一时序点落地会导致 "先复制一行内容、随后不断增殖"。以下 hand-run 用例直接验证该路径。

| # | 场景 | 操作步骤 | 期望 | 失败信号 |
|---|------|---------|------|---------|
| 1 | 行尾窄字符写入 | 光标置最后一列，输入 `A` | `A` 仅出现在当前行末尾，下一行不受影响 | 上/下一行出现多余 `A` |
| 2 | 行尾窄字符 → 再输入 | 场景 1 后再输入 `B` | `B` 换行到下一行开头 | `B` 覆盖当前行内容或与 `A` 重叠 |
| 3 | 行尾宽字符写入 | 光标置倒数第二列，输入宽字符 `中` | `中` 占两格或触发换行，无残影 | 宽字符只写一格、右格残留旧内容 |
| 4 | copy-then-delete | 选中文本 → 粘贴到行尾 → 立即 delete 删除 | 删除后行恢复到粘贴前状态 | delete 只删了可见内容，dirty mark 没清，下一帧又渲染出粘贴内容 |
| 5 | 持续光标移动增殖 | 触发场景 4 后，用方向键左右移动光标 | 内容保持不变，不出现新的"复制体" | 每次移动都多出一份相同内容 |
| 6 | 行尾 + INSERT 模式 | 进入 INSERT mode，在行尾输入字符 | 不 shift（insert 无意义）且无内容增殖 | 行尾内容被错写到其他位置 |
| 7 | wrapnext 连续写入 | 光标已在行尾并设 CURSOR_WRAPNEXT，输入 `X` | `X` 换行到下一行开头，当前行不改动 | `X` 出现在当前行或其他随机位置 |
| 8 | overflow 连续写入 | 光标在行末且无 wrapnext，输入超出列数的字符 | 触发 overflow 逻辑换行 | 内容截断或写到上一行 |
