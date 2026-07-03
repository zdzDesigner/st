Title: c commit harness
Status: ready-for-agent
Progress: in-progress

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
