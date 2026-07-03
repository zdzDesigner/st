Title: c commit harness
Status: ready-for-agent
Progress: completed

## Goal

给 `tcommitputcwrite(...)` 搭一个最小 C-side harness，直接验证 `term` 全局上的 dirty / `CURSOR_WRAPNEXT` / cursor move 提交时序。

## Scope

- `st.c` 中与 `tcommitputcwrite(...)` 最接近的可测试 seam
- 构建入口中最小额外测试接线
- 必要的 mock `term` / 单行 buffer 测试夹具

## Boundary

- 只测试 `tcommitputcwrite(...)` 提交协议，不扩到完整 X11/TTY 运行时。
- 不引入大型新测试框架。
- 优先最小 harness，而不是通用 C 测试基础设施。

## Dependencies

- `01-extract-putc-commit-helper`
- `02-putc-commit-regression-coverage`

## Blocked by

- 无

## Acceptance criteria

- 能自动断言至少两类场景：MOVE 分支和 WRAPNEXT 分支。
- 能直接观察 dirty 标记与 cursor state/position 在 `term` 上的提交结果。
- `zig build test` 或等价项目测试入口可运行该 harness。

## Validation

- `zig build test`
- `zig build`
- `timeout 5 ./zig-out/bin/st`

## Comments

- 2026-07-03 Observe: `putc-atomic-commit-owner` 的前两步已完成，但当前自动化证据仍缺 C-side `term` 全局提交时序验证。下一轮专门解决这一缺口。
- 2026-07-03 Draft/Review round 1: 初版 harness 增加了 `st_c_harness.c` / `st_c_harness_test.zig` / `build.zig` 测试接线，但最初只是复制 `tcommitputcwrite` 语义。`code-reviewer` 指出这不能构成真实回归保护。
- 2026-07-03 Draft/Review round 2: 新建共享头 `st_commit_putc.h`，把 commit 协议收口成单一 `commit_putc(...)` 实现；`st.c` 的真实 `tcommitputcwrite(...)` wrapper 与 harness 都调用同一份共享协议。最终复审通过。
- 2026-07-03 Final-Verify round 1: `zig build abi-check` 失败，原因是共享 helper 初始命名为 `st_commit_putc`，误命中 repo 的 ABI 守卫；已重命名为 `commit_putc` 后恢复通过。
- 2026-07-03 Validation: `zig build abi-check`、`zig build test`、`zig build`、`timeout 5 ./zig-out/bin/st` 全部通过。实现完成。
