Title: 设计 Search matches seam
Status: completed

## What to build

基于已经存在的 `SearchScalarState`、`SearchInputState` 和 query replace seam，设计 `matches` 相关的下一层边界，明确哪些状态属于可共享的标量视图，哪些仍是 C 侧数组指针和扩容副作用。这个 slice 先收敛边界，不迁移 `matches` ownership。

## Proposed boundary

- `matches` 数组指针与 `xrealloc/free` 生命周期继续留在 C。
- 与 `matches` 直接相关的共享状态先收口为一个轻量 view：`count` 与 `cap`。
- Zig 继续负责：
  - `current` 合法性与归一化
  - 扫描时是否需要 grow
  - append 的 match 值对象内容
- C 继续负责：
  - 真正的 `xrealloc`
  - `SearchMatch` 数组写入
  - `search.matches` 指针本体

## Proposed slices

1. 引入 `SearchMatchesState`，让 `searchscan/searchscanline/searchjump/searchmatch/searchcurrent` 优先消费 `count/cap` 视图。
2. 为 `SearchMatchesState` 和 `st_searchscanupdate/st_searchlineplan` 补边界测试。
3. 只有当 count/cap seam 稳定且明显减少复杂度时，再评估是否需要更深的 `matches` object seam。
4. 默认不迁移 `matches` ownership；只有 deletion test 证明指针 ownership 留在 C 造成了持续复杂度时才继续。

## Risk boundary

- 低风险：提取 `count/cap` 共享视图，减少散读散写。
- 中风险：把扫描事务进一步收口成单一 helper。
- 中高风险：迁移 `matches` 指针 ownership 或让 Zig 驱动真实数组生命周期。

## Acceptance criteria

- [x] 明确 `matches` 的标量边界与数组 ownership 边界
- [x] 给出后续 vertical slices 顺序与风险边界
- [x] 设计保持 `SearchModel` / C effect shim 现有分工，不回退到浅层 helper

## Blocked by

None - can start immediately
