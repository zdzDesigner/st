Title: 接入 selsnap 的 word loop 垂直切片
Status: completed

## What to build

把 `selsnap()` 的 `SNAP_WORD` 路径改成由 Zig 主导 loop 控制。C 只根据 Zig 请求读取 glyph、delimiter、line length 和 wrap 事实，再把这些事实回填给 Zig，最终完成与现有行为一致的 word snap 端到端路径。

## Acceptance criteria

- [x] `selsnap()` 的 `SNAP_WORD` 不再自己维护 delimiter 状态机和停止规则
- [x] C 侧只保留 reader/effect shim：读取 `TLINE(...)`、`tlinelen(...)`、wrap 事实并写回最终坐标
- [x] `zig build abi-check`、`zig build test` 和 `zig build` 通过，且行为没有已知回退

## Blocked by

- `.scratch/selection-snap-word-iterator/issues/01-define-snapworditerator-interface.md`
