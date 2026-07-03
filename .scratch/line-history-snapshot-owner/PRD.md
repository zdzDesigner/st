# Line History Snapshot Owner

## Goal

围绕 `Line/History owner` 先做读模型迁移：把 `term.line` / `term.hist` / `term.scr` / `term.histi` 的读取事实收口成显式 snapshot seam，先统一“怎么读”，暂不迁写模型和 ownership。

## Evidence

- `docs/zig-architecture.md:25` 明确阶段 2 是 `Line/History owner`，目标是给 `term.line`、`term.alt`、`term.hist`、`term.histi` 设计 `snapshot/update/effect seam`。
- `docs/zig-architecture.md:28` 明确切片顺序必须先迁读模型，再迁写模型，最后迁资源 ownership。
- `st.c:443-453` 当前 `tlinehist()` / `tlineviewport()` 仍直接读取 `term.hist`、`term.line`、`term.scr`、`term.histi`，是最核心的 line/history 读取入口。
- `docs/architecture-flow.md:211` 明确 `externalpipe()` 仍保留历史/当前行指针获取；`st_tlinehistplan()` 已下沉到 `st_search.zig`，说明 history line 读取边界已有部分 Zig 化基础。
- `docs/zig-architecture.md:89-90` 当前只收口了 `term.scr` / `term.histi` 标量写回，`term.hist` / `term.line` 指针和资源生命周期仍留在 C。

## Non-goals

- 本 feature 不迁移 `term.line` / `term.hist` ownership。
- 本 feature 不改 scroll pointer swap / resize transaction。
- 本 feature 不一次性替换所有 `TLINE(...)` 调用点。

## Task Queue

1. `01-history-read-snapshot`
2. `02-tline-read-adoption`

## Status

- `01-history-read-snapshot`: completed
- `02-tline-read-adoption`: completed

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`
- `timeout 5 ./zig-out/bin/st`

以上命令已在 `02-tline-read-adoption` 完成后通过。
