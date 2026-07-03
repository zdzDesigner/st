Title: platform effect ordering plan
Status: ready-for-agent
Progress: todo

## Goal

在前三类 owner seam 稳定后，规划 Platform shim 的 effect ordering 收口范围，不迁移平台资源 ownership。

## Scope

- `platformapplyeffects()` / `platformapplydraweffect()`
- `xsettitle()` / `xseticontitle()` / `xsetcolorname()` / `xloadcols()`
- `xclipcopy()` / `setsel()` / `selnotify()` / `selrequest()`
- `ttywrite()` / `externalpipe()` / `ttynew()`

## Boundary

- 不迁移 X11 display/window/font/color、PTY fd、clipboard selection、OS fd/process ownership。
- 不重排 focus color reload、RIS reset、OSC/platform string effects。

## Dependencies

- `02-escape-machine-boundary-review`
- `03-line-history-transaction-boundary-review`
- `04-selection-ownership-reopen-check`
- `05-search-buffer-ownership-reopen-check`

## Blocked by

- `.scratch/terminal-effect-owner-roadmap/issues/02-escape-machine-boundary-review.md`
- `.scratch/terminal-effect-owner-roadmap/issues/03-line-history-transaction-boundary-review.md`
- `.scratch/terminal-effect-owner-roadmap/issues/04-selection-ownership-reopen-check.md`
- `.scratch/terminal-effect-owner-roadmap/issues/05-search-buffer-ownership-reopen-check.md`

## Acceptance criteria

- [ ] 明确 Platform shim 只允许做 effect ordering plan 的范围。
- [ ] 明确所有资源 ownership 仍留在 C 的证据。
- [ ] 明确进入 platform code migration 前的 blocker。

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`

## Comments
