Title: 扩大 SearchScalarState 调用点采用范围
Status: completed

## What to build

继续把 `search` 子系统里仍直接读取 `search.qlen`、`search.active`、`search.current`、`search.inputmode`、`search.inputlen`、`search.inputcursor`、`search.inputcap`、`search.nmatches`、`search.cap` 的纯标量逻辑，收口到 `SearchScalarState` 共享读写视图。这个 slice 不改变 `query/input/matches` 的资源所有权，只减少 C 侧重复理解同一组标量字段。

## Acceptance criteria

- [x] 额外一批 Search 调用点改为优先通过 `SearchScalarState` 读取/写回标量状态
- [x] 不新增新的 Search 标量字段映射 helper 分支，继续沿用现有 seam
- [x] `zig build abi-check`、`zig build test`、`zig build` 通过

## Blocked by

None - can start immediately
