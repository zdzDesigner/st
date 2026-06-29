Title: 设计 Mode exec action seam
Status: completed

## What to build

把 `tsetmode()` 中最容易验证的 alternate screen / cursor save-load action 顺序从 C switch 中收口到 Zig plan。这个 slice 不迁 X11/terminal 副作用 ownership，C 仍执行 `xsetmode`、`tcursor`、`tswapscreen`、`tclearregion`、`tmoveto`。

## Proposed seam

- `st_modeplan()` 继续分类 mode kind。
- `ZigModePlan` 增加低风险 action fields：
  - `cursor_before`
  - `clear_before_swap`
  - `swap_screen`
  - `cursor_after`
- Zig 负责 `1049/47/1047/1048` 的 action 顺序。
- C 负责执行 action，并保留 `allowaltscreen` gate 和真实副作用。

## First slice

只处理 alternate screen / cursor action：

- `1049 set`：save cursor -> swap screen
- `1049 reset`：load cursor -> clear old alt screen -> swap screen -> load cursor
- `47/1047`：clear old alt screen -> optional swap
- `1048`：save/load cursor only

## Deferred

- mouse modes
- origin mode reset
- bracketed paste
- regular mode bit flips
- unknown mode diagnostics

## Ownership decision

不迁 mode effect ownership。Zig 只规划 action；C 继续持有 terminal mode bit writes、X11 calls、screen swap、clear and cursor side effects。

## Acceptance criteria

- [x] `tsetmode()` 不再用 fallthrough 表达 alternate screen/cursor action 顺序
- [x] action 顺序由 Zig tests 覆盖
- [x] `zig build abi-check` 通过
