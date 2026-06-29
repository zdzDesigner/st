Title: 设计 Mouse mode action seam
Status: completed

## What to build

把 `tsetmode()` 中 mouse mode 的重复 action 顺序收口到 `ZigModePlan`。这个 slice 不迁 X11 effect ownership，C 仍执行 `xsetpointermotion()` 和 `xsetmode()`。

## Proposed fields

- `pointer_motion`
  - `-1` 表示不调用
  - `0/1` 表示调用 `xsetpointermotion(value)`
- `clear_mouse_mode`
  - `1` 表示先执行 `xsetmode(0, MODE_MOUSE)`
- `mouse_mode`
  - `none/x10/button/motion/many/sgr`
  - C 只把 enum 映射为真实 `MODE_MOUSE*` bit 并执行 `xsetmode(set, bit)`

## Covered modes

- `9` -> X10 mouse
- `1000` -> button mouse
- `1002` -> motion mouse
- `1003` -> many mouse
- `1006` -> SGR mouse
- `1005` remains ignored

## Deferred

- Origin/wrap/visibility mode actions
- Regular mode bit writes
- Unknown diagnostics

## Acceptance criteria

- [x] C mouse cases consume action fields rather than owning repeated sequence
- [x] tests cover X10/button/motion/many/SGR and ignored 1005
- [x] C still owns X11 calls and mode bit writes
