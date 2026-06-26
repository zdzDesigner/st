Title: 评估 Search query ownership seam
Status: completed

## What to build

评估 `search.query` 是否值得迁移 ownership，并给出最小风险的过渡顺序。这个 slice 先收敛边界和风险，不直接把 `Rune *query` 的生命周期迁给 Zig。

## Evaluation

- 当前不建议直接迁 `query` ownership。
- 原因不是“做不到”，而是收益不足：`searchset()` 仍必须在 C 里执行 UTF-8 decode，随后还要执行指针替换、scan、jump、redraw。这些 effect 就算 ownership 迁到 Zig，仍要回到 C shim 执行。
- 直接迁 ownership 会增加 Zig/C 间的资源生命周期协议，但不会显著减少 `searchset()` 当前的多阶段时序复杂度。
- 当前更高杠杆的切口，是继续把 `searchset()` 的 alloc/decode/apply 三段事务拆清楚，让 ownership 是否值得迁移变成一个后验问题，而不是先验假设。

## Proposed slices

1. 抽出 `query alloc phase seam`：只负责 `alloc_len` 阶段与 `Rune *` 预分配。
2. 抽出 `query apply phase seam`：只负责 decode 完成后的 `clear_query`、指针替换、状态写回和后续 effect。
3. 为 alloc/apply 双阶段补事务测试。
4. 只有当两段 seam 都稳定后，再评估是否还需要 `SearchOwnedQuery` 之类的更深 object。

## Risk boundary

- 低风险：拆 alloc/apply 两阶段 helper、补测试。
- 中风险：引入 query object，但指针 ownership 仍留在 C。
- 中高风险：把 `search.query` 指针与 free 生命周期交给 Zig。
- 高风险：把 query/input/matches 三个 ownership 在同一批里推进。

## Acceptance criteria

- [x] 明确为什么当前不直接迁 query ownership
- [x] 给出更小的过渡切片顺序
- [x] 保持现有 `SearchModel` / C effect shim 分工，不回退到浅层 helper

## Blocked by

None - can start immediately
