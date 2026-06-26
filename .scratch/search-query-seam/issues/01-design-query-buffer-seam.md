Title: 设计 Search query buffer seam
Status: completed

## What to build

基于已经存在的 `SearchScalarState` 和 `SearchInputState`，设计 `query` buffer 的下一层 seam，明确 UTF-8 decode 前后的状态更新、query 指针替换、clear/free 顺序，以及哪些职责继续保留在 C effect shim。这个 slice 先收敛边界，不直接迁移 `query` 的资源所有权。

## Proposed boundary

- `query` 指针本体和 `Rune *` 生命周期继续留在 C；Zig 仍不直接持有 `query` 的分配/释放所有权。
- `query_len` 与 decoded `qlen` 的双阶段语义继续保留：
  - 第一阶段：C 用原始 UTF-8 字节长度调用 `st_searchsetupdate(..., query_len, 0)`，只拿 `alloc_len`
  - 第二阶段：C 完成 UTF-8 decode 后，再用真实 `qlen` 调用 `st_searchsetupdate(..., query_len, qlen)` 获取最终 `SearchStateUpdate + SearchEffectPlan`
- `alloc_query` / `clear_query` 继续只表达 effect，不直接表达所有权迁移。C 负责：
  - 执行 `free(search.query)`
  - 执行 `search.query = runes` 指针替换
  - 决定 `searchscan()` 与 `searchjump()` / `redraw()` 的最终 effect 顺序
- 下一层 seam 的目标不是把 `query` 指针交给 Zig，而是先把“query 替换事务”收口成单一 C helper，避免 `searchset()` 同时展开 decode、free、replace、scan、jump 的时序知识。

## Proposed slices

1. 抽出 `query` replace transaction seam：集中 `clear_query`、`search.query = runes`、`searchapplyupdate()`、`searchscan()`、`searchapplyvieweffect()` 的执行顺序。
2. 为 `searchset()` 的双阶段 contract 补测试：分别覆盖 alloc 阶段与 decoded apply 阶段。
3. 评估是否需要单独 `SearchQueryState` 值对象；只有当它能减少调用点时序知识时才引入，否则保持在 helper 层。
4. 最后再判断 `query` ownership 是否值得从 C 迁到 Zig；如果只是把 free/replace 换个位置而不减少复杂度，则不迁。

## Risk boundary

- 低风险：把 `searchset()` 的替换时序收口到单一 helper，补双阶段测试。
- 中风险：引入 `SearchQueryState` 之类的新值对象，并让更多调用点围绕它组织。
- 中高风险：把 `query` 指针及其 `malloc/free` 生命周期迁给 Zig。
- 高风险：把 `query` ownership 和 `matches` / `input` ownership 在同一批里同时迁移。

## Acceptance criteria

- [x] 明确 `query_len`、decoded `qlen`、query 指针替换与 clear/free 的时序契约
- [x] 明确 Zig 返回的状态/副作用边界，不回退到新增浅层 helper
- [x] 给出后续 vertical slices 的顺序，说明何时才值得碰 `query` ownership

## Blocked by

None - can start immediately
