Title: 设计 Search input ownership seam
Status: completed

## What to build

基于已经存在的 `SearchScalarState`、`SearchInputState`、query replace seam 和 matches seam，评估 `input` buffer 是否值得迁移 ownership，并给出最小风险的后续切片顺序。这个 slice 先收敛边界，不直接把 `search.input` 的 `malloc/realloc/free` 生命周期迁给 Zig。

## Proposed boundary

- `search.input` 指针和 `xmalloc/xrealloc/free` 生命周期暂时继续留在 C。
- Zig 继续只持有 `input` 的语义状态：
  - `active`
  - `len`
  - `cursor`
  - `cap`
  - 插入/删除/移动后的目标状态与位移计划
- C 继续负责：
  - `xmalloc/xrealloc/free`
  - `memmove/memcpy`
  - `search.input[...]= '\0'`
  - 把字符串视图传回 `searchset()`
- ownership 真正迁移前，先把 `input` 的“变更事务”收口成单一 helper，避免 `searchinput()/searchdelete()/searchapplystate()` 分散理解 realloc、move、终止符写入顺序。

## Evaluation

- 现在直接迁 `input` ownership 的收益不够高，因为 Zig 仍无法直接执行 `xrealloc/memmove`，最后还得回到 C effect shim。
- 如果现在强行迁 ownership，只会把“谁持有指针”改掉，但不会显著减少 `searchinput()` 的时序复杂度。
- 当前更高杠杆的步骤不是迁 ownership，而是先把 `input` 相关的变更事务收口成单一 seam，等时序知识集中后再评估 ownership 是否仍有必要。
- 当前结论已经可以明确：`input ownership` 暂不迁到 Zig。原因是 input 的关键复杂度仍然落在 C 执行面：`xmalloc/xrealloc`、`memmove/memcpy`、`'\0'` 终止符写入和最终 `searchset()` 触发。ownership 迁移会增加 Zig/C 生命周期协议，但不会显著减少这些时序步骤。

## Proposed slices

1. 抽出 input mutation transaction seam：集中 `realloc_input`、`memmove/memcpy`、`'\0'` 终止符写入与最终 `searchset()` 触发。
2. 为 input mutation seam 补事务测试，覆盖 grow / in-place insert / delete / clear-input。
3. 只有当事务 seam 稳定后，再评估是否需要 `SearchOwnedInput` 之类的更深 object。
4. 当前决定是不迁 `search.input` ownership；只有 deletion test 证明 C 持有指针持续制造复杂度时才重新评估。

## Risk boundary

- 低风险：抽 transaction seam、补测试、减少时序散落。
- 中风险：引入更深的 input object，但 ownership 仍留在 C。
- 中高风险：把 `search.input` 指针与 `realloc/free` 生命周期交给 Zig。
- 高风险：在迁 input ownership 的同时再叠加 query/matches ownership。

## Acceptance criteria

- [x] 明确 input 语义状态与指针 ownership 的分工
- [x] 明确为什么当前不直接迁 ownership
- [x] 给出后续 vertical slices 顺序与风险边界

## Blocked by

None - can start immediately
