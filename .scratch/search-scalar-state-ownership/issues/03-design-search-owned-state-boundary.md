Title: 设计 Search 更深的权威状态边界
Status: completed

## What to build

基于已经收口的 `SearchScalarState` seam，设计下一层更深的 Search 权威状态边界，明确哪些状态继续由 C 持有，哪些状态可以迁到 Zig，以及 `query/input/matches` 的资源生命周期如何保持可控。这个 slice 的目标是收敛接口与迁移顺序，不要求一次迁完资源所有权。

## Proposed boundary

- `SearchScalarState` 继续作为第一层 C/Zig 共享状态边界，负责 `query_len`、`active`、`current`、`inputmode`、`inputlen`、`inputcursor`、`inputcap`、`nmatches`、`match_cap` 的读写往返。
- `query`、`input`、`matches` 三个 buffer 的指针与生命周期暂时继续留在 C；Zig 只消费切片/长度视图，不直接接管分配与释放。
- Zig 继续持有状态转移与副作用规划的权威语义：`SearchModel` 输出 `SearchStateUpdate` 和 `SearchEffectPlan`，C 只执行 `xmalloc`、`xrealloc`、`free`、`memmove`、`searchscan`、`searchjump`、`redraw` 等 effect。
- 下一层更深的边界不应直接把三个 buffer 一次性交给 Zig；应优先先把单个 buffer 的“状态语义”和“资源生命周期”拆开，再做 vertical slice。

## Proposed slices

1. 扩大 `SearchScalarState` 覆盖到剩余纯标量 Search 调用点，并清理重复读写。
2. 为 `searchscanline()` 和匹配容量更新建立更明确的 `matches` 容量/计数 seam，但仍由 C 持有数组指针。
3. 单独设计 `input` buffer ownership seam，让 Zig 可以更明确地描述 cursor/len/cap 关系，C 仍执行 realloc/memmove。
4. 单独设计 `query` buffer ownership seam，让 UTF-8 decode 前后的状态更新、query 替换和 clear/free 顺序变成单一契约。
5. 最后再评估 `matches` 数组 ownership 是否值得迁移到 Zig；如果 deletion test 证明收益低，可以长期保留在 C。

## Risk boundary

- 低风险：继续扩大 `SearchScalarState` 使用面、补测试、减少重复映射。
- 中风险：把 `input` 或 `query` 的状态语义从“标量 + effect”推进到更深的 object seam。
- 中高风险：迁移任一 buffer 的真实分配/释放所有权。
- 高风险：在同一批里同时迁 `input/query/matches` 多个资源所有权，或让 Zig 直接承担 `malloc/free` 生命周期。

## Acceptance criteria

- [x] 形成一份明确的 Search 状态边界设计，区分标量状态、buffer 指针和副作用职责
- [x] 给出后续 vertical slices 的顺序，明确先后依赖和风险边界
- [x] 设计与当前 `SearchModel`、`SearchScalarState` 和 C effect shim 保持一致，不回退到新增浅层 helper

## Blocked by

- `.scratch/search-scalar-state-ownership/issues/02-add-searchscalarstate-transition-tests.md`
