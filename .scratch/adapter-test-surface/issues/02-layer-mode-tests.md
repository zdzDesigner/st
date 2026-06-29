Title: 分层 st_mode tests
Status: completed

## What changed

把 `st_mode.zig` tests 按 domain / adapter smoke 分层：

- domain tests 直接覆盖：
  - `modePlan(...)`
  - `pointerMotion(...)`
  - `clearMouseMode(...)`
  - `mouseMode(...)`
  - `cursorStateAction(...)`
  - `termModeAction(...)`
  - `xsetmodeAction(...)`
- adapter smoke tests 只保留：
  - `st_modeplan()`
  - `st_tdefutf8()`
  - `st_tdeftran()`

## Outcome

`st_mode.zig` 不再让 export tests 承担完整领域行为覆盖。
