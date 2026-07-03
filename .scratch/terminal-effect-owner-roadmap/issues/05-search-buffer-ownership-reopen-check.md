Title: search buffer ownership reopen check
Status: ready-for-agent
Progress: completed

## Goal

复查 Search owner 的 query/input/matches buffer ownership 是否仍应保持 C 持有，或是否出现新的可验证迁移切片。

## Scope

- `searchset()` query replace transaction
- `searchinput()` input mutation transaction
- `searchapplymatchestransaction()` / `searchscanline()` matches write path
- `searchjump()` / `searchapplyvieweffect()` redraw and scroll effects

## Boundary

- 不迁移 `Rune *query`、`char *input`、`SearchMatch *matches` ownership，除非本 issue 先证明收益和验证路径。
- 不把 realloc/memmove/memcpy/free 搬入 Zig。

## Dependencies

- `01-owner-roadmap-freeze`

## Blocked by

- `.scratch/terminal-effect-owner-roadmap/issues/01-owner-roadmap-freeze.md`

## Acceptance criteria

- [x] 复核当前 search buffer ownership 决策是否仍成立。
- [x] 如果继续保持 C ownership，记录理由和 reopen 条件。
- [x] 如果存在安全切片，新增具体 AFK issue。

## Validation

- `zig build abi-check`
- `zig build test`
- `zig build`

## Comments

- 2026-07-03 Frame: 本切片按 `docs/terminal-effect-ordering.md` 的 heap mutation、line/history fact reading、search scan/edit/jump 决策和 C executor ownership 护栏复查 Search buffer ownership。
- 2026-07-03 Evidence: `st.c:686` 至 `st.c:763` 显示 C 侧已通过 `SearchScalarState -> ZigSearchSnapshot -> ZigSearchStateUpdate` 集中读写 search 标量状态；`st_search.zig:285` 至 `st_search.zig:354` 明确 snapshot/update/effect 只携带标量和 effect，不持有 buffer 本体。
- 2026-07-03 Evidence: `st.c:814` 至 `st.c:834` 显示 query replace 仍由 C 执行 `strlen()`、`xmalloc()`、`utf8decode()`、`Rune *` 写入和指针替换；`st_search.zig:1378` 至 `st_search.zig:1417` 只返回 alloc_len、状态和 clear/refresh/jump/redraw effect。
- 2026-07-03 Evidence: `st.c:836` 至 `st.c:884` 和 `st.c:894` 至 `st.c:913` 显示 input mutation 仍由 C 执行 `xrealloc()`、`memmove()`、`memcpy()`、nul termination；`st_search.zig:650` 至 `st_search.zig:852` 只计算 input insert/delete/move/cursor 的字节范围和状态更新。
- 2026-07-03 Evidence: `st.c:962` 至 `st.c:1037` 显示 matches scan transaction 仍由 C 遍历可见行和历史行、读取 `term.line[]` / `term.hist[]`、执行 `xrealloc()` 和 `SearchMatch` 数组写入；`st_search.zig:169` 至 `st_search.zig:199`、`st_search.zig:1499` 至 `st_search.zig:1503` 只持有 scan iterator state 和 append/grow/stop 决策。
- 2026-07-03 Evidence: `.scratch/search-buffer-ownership-review/issues/01-boundary-review.md:12` 至 `.scratch/search-buffer-ownership-review/issues/01-boundary-review.md:18` 已记录同一结论：query、input、matches ownership 暂不迁，协议成本高于 shim-thinning 收益。
- 2026-07-03 Decision: 不重开 Search buffer ownership 迁移。当前 Search seam 已把领域规则集中在 `SearchModel`、`Input`、`InputEditor`、`SearchScanIterator`、`Matches` 和 `Jump`，删除这些 module 会把 UTF-8 cursor、insert/delete、scan append/grow、current normalize、jump scroll 规则重新摊回 C；但 buffer pointer 生命周期仍天然属于 C executor。
- 2026-07-03 Reopen condition: 只有当出现明确计划迁移 `Rune *query`、`char *input` 或 `SearchMatch *matches` 的资源 ownership，并同步提供 allocator/lifetime/error/rollback 协议和对应回归测试时，才新增 AFK 实现切片。当前不新增实现 issue。
- 2026-07-03 Validation target: 本切片为 boundary review，验证命令使用 `zig build abi-check`、`zig build test`、`zig build`。
