Title: 设计 Origin 与 simple mode action seam
Status: completed

## What to build

把 `tsetmode()` 中剩余低风险 mode actions 收口到 `ZigModePlan`，包括 origin、visibility 和 simple bit writes。这个 slice 不迁 unknown diagnostics。

## Proposed fields

- `cursor_state_action`
  - `none/origin`
- `cursor_state_set`
  - `0/1`
- `move_origin_home`
  - `1` 表示执行 `tmoveato(0, 0)`
- `term_mode_action`
  - `none/wrap/insert/echo/crlf`
- `term_mode_set`
  - 最终写入值，避免把 `!set` 这种翻转逻辑留在 C
- `xsetmode_action`
  - `none/hide/kbdlock`
- `xsetmode_set`
  - 最终传给 `xsetmode`

## Covered modes

- private: `6` origin, `7` wrap, `25` cursor visibility
- regular: `2` kbdlock, `4` insert, `12` echo, `20` crlf

## Deferred

- unknown diagnostics
- higher-risk mode action batching beyond current fields

## Acceptance criteria

- [x] `MODE_ORIGIN` 的 bit write + `tmoveato(0,0)` 顺序由 Zig plan 决定
- [x] visibility / simple bit writes 不再让 C 持有 `set` / `!set` 规则
- [x] unknown diagnostics 仍保留在 C
