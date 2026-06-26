# 架构改进报告

日期：2026-06-26

## 背景

本报告基于当前 C/Zig 混合架构扫描生成。项目目标已经在 `docs/zig-architecture.md` 中明确：C 逐步收缩为极薄 shim，Zig 逐步接管 `term`、`sel`、`search` 等状态模型和主线决策。

当前架构的主要 seam 是 `st_zig.h` 暴露的 C ABI。C 仍负责 X11、PTY、clipboard、IO、全局状态和实际副作用；Zig 负责值类型模型、状态机、范围计算、编辑计划、匹配计划和可单元测试的纯逻辑。

本报告使用以下 architecture 词汇：

- **Module**：任何有 interface 和 implementation 的代码单元。
- **Interface**：caller 为正确使用 module 必须知道的一切，包括类型、约束、调用顺序和错误模式。
- **Seam**：可以不在原地编辑就改变 behaviour 的 interface 所在位置。
- **Adapter**：在 seam 处满足 interface 的具体实现。
- **Depth**：interface 的 leverage。小 interface 背后有大量 behaviour，就是 deep module。
- **Locality**：change、bug、知识和验证集中在一个地方。
- **Leverage**：caller 学会一个小 interface 后获得更多能力。

## 总结

| 优先级 | 候选 | 主要文件 | 建议强度 |
| --- | --- | --- | --- |
| 1 | 深化 Search 写模型所有权 | `st.c`、`st_search.zig`、`st_line.zig` | Strong |
| 2 | 拆分 `st_line.zig` adapter hub | `st_line.zig`、`st_search.zig`、`st_selection.zig` | Done |
| 3 | 深化 Selection snap | `st.c`、`st_line.zig`、`st_selection.zig` | In progress |
| 4 | 删除 pass-through exports | `st_misc.zig`、`st_edit.zig`、`st_csi.zig`、`st.c` | Done |
| 5 | 深化 Mode actions | `st_mode.zig`、`st.c`、`st_csi.zig` | Worth exploring |
| 6 | 收窄 adapter tests | `st_line.zig`、`st_search.zig`、`st_selection.zig` | Speculative |

## Top Recommendation

优先推进 **Search 写模型所有权迁移**。

原因：项目文档已经把 `search` 定为第一批状态所有权迁移入口；当前读模型已经进入 `SearchSnapshot -> SearchStateUpdate/SearchEffectPlan` 形态，但 C 侧仍通过 `searchapplyupdate()` 机械写回字段。这是一个高信心、路线清晰、收益直接的 deepening opportunity。

## 候选 1：深化 Search 写模型所有权

### Files

- `st.c`：`searchprompt()`、`searchinput()`、`searchset()`、`searchapplycursor()`、`searchapplystate()`、`searchapplyupdate()`。
- `st_search.zig`：Search 领域状态机和纯逻辑。
- `st_line.zig`：Search 相关 C ABI adapter。
- `docs/zig-architecture.md`：Search 状态所有权迁移路线。

### Problem

Search 读模型已经迁移到 `SearchSnapshot`，但写模型仍泄漏在 C shim。C 侧通过 `searchapplyupdate()` 把 `SearchStateUpdate` 逐字段写回 `search.qlen`、`search.active`、`search.current`、`search.inputmode`、`search.inputlen`、`search.inputcursor`、`search.inputcap`、`search.nmatches`、`search.cap`。

这个 module 的 interface 仍然偏 shallow：Zig 已经决定下一状态，但 C caller 仍必须知道每个字段如何落回全局状态。

### Solution

在 `st_search.zig` 中引入更 deep 的 `SearchModel` module，让 Zig 持有权威 search 状态转换。C shim 只作为 effect adapter，执行 `xmalloc`、`xrealloc`、`free`、`redraw`、`searchscan`、`searchjump` 等平台副作用。

### Benefits

- **locality**：search 状态读写集中在 `st_search.zig`。
- **leverage**：一个 `SearchModel` interface 覆盖 prompt、input、cursor、state、set、scan 等行为。
- **test surface**：测试直接覆盖 Search 写模型，不再通过 C 字段回写间接验证。
- **deletion test**：删除 C 侧机械写回后，复杂性不会消失，而是集中到 Zig 状态 module，说明这是值得深化的 module。

### Recommendation Strength

已完成第一轮：Search adapter implementation 已下沉到 `st_search.zig`，Selection adapter implementation 已下沉到 `st_selection.zig`，`st_line.zig` 目前只保留 search/selection export 的过渡 shim。

## 候选 2：拆分 `st_line.zig` adapter hub

### Files

- `st_line.zig`：line、selection、search/history 的集中 adapter。
- `st_search.zig`：Search 领域逻辑。
- `st_selection.zig`：Selection 领域逻辑。

### Problem

`st_line.zig` 同时承担 line、selection、search/history 三个 adapter 角色。Search adapter 中多次重复 `ZigSearchSnapshot -> SearchSnapshot` 和 `SearchResult -> ZigSearchResult` 字段转换；Selection adapter 也有类似转换。

这让 `st_line.zig` 的 interface 和 implementation 都变宽，adapter hub 本身变成 shallow module。维护者理解一个 search 改动时，需要在 `st_search.zig` 和 `st_line.zig` 之间来回跳。

### Solution

把 Search adapter 移到 `st_search.zig` 附近，把 Selection adapter 移到 `st_selection.zig` 附近。`st_line.zig` 保留真正 line 相关 adapter。

### Benefits

- **locality**：Search adapter 跟 Search domain module 放在一起，Selection adapter 跟 Selection domain module 放在一起。
- **leverage**：每个领域 module 拥有自己的 extern conversion interface。
- **interface shrink**：`st_line.zig` 不再暴露不属于 line 的 search/selection 知识。
- **test surface**：adapter smoke test 可以贴近对应 domain module。

### Recommendation Strength

Strong。

## 候选 3：深化 Selection snap

### Files

- `st.c`：`selsnap()`。
- `st_line.zig`：`st_selsnapwordplan()`、`st_selsnapwordloopstep()`。
- `st_selection.zig`：`snapWordPlan()`、`snapWordStep()`、`snapWordLoopStep()`。

### Problem

Selection snap 当前在 C 循环中反复跨 seam。C 读取 `TLINE(...)` 和 delimiter，调用 Zig 获取一步 plan，再回到 C 更新坐标，然后继续下一轮。

`st_selsnapwordloopstep()` 的 interface 需要传入大量拆散后的状态：坐标、wrap 信息、line length、mode、delimiter、previous delimiter、rune、previous rune。这个 interface 几乎暴露了 implementation 的每个细节，是 shallow module 信号。

### Solution

引入 `SnapWordIterator` 或类似 module，让 Zig 持有 snap loop。C 只提供 glyph 读取 adapter 或一次性传入必要的 glyph slice。完整 snap 行为留在 Zig implementation 内部。

### Benefits

- **locality**：snap 循环、delimiter 状态、wrap 行为集中在 `st_selection.zig`。
- **interface shrink**：删除 13 参数级别的 step interface。
- **leverage**：一个 snap interface 覆盖完整路径，而不是每次只推进一步。
- **test surface**：测试完整 snap 行为，不再只测试单步 plan。

### 状态

已完成：`st_tdectest`、`st_ttywritecount`、`st_tprinterwrite`、`st_sttyfits`、`st_ttyreadpending`、`st_tscrollselplan`、`st_csiprivbool` 已通过 deletion test 删除，C 调用点改为等价表达式，`st_zig.h` 已同步移除声明。

## 候选 4：删除 pass-through exports

### Files

- `st_misc.zig`：若干一行判断 export。
- `st_edit.zig`：`st_tscrollselplan()`。
- `st_csi.zig`：`st_csiprivbool()`。
- `st.c`：对应调用点。

### Problem

部分 `export fn st_*` 只是包装一行 C 本来也能直接表达的比较逻辑，例如 `c == '8'`、`iofd != -1`、`buflen > 0`、`scr == 0`、`priv != 0`。

这些 module 删除后，复杂性不会在多个 caller 重新出现，只会消失。因此它们没有提供 depth，也没有提供 leverage。

### Solution

对这些 export 逐个做 deletion test：在 C 调用点内联等价表达式，删除 Zig export、`st_zig.h` 声明和仅测试比较语法的测试。

### Benefits

- **interface count drops**：减少 ABI surface。
- **locality**：简单条件留在使用点。
- **leverage clarity**：保留真正隐藏复杂性的 Zig module。
- **test surface**：删除测试语言内置比较的低价值测试。

### Recommendation Strength

In progress。第一步已把 `st_selsnapwordloopstep` 的 13 个散参数收口为 `ZigSelSnapWordLoopSnapshot`，并引入 `SnapWordLoop` module 承载 step implementation；完整 loop 迁移到 `SnapWordIterator` 仍待 glyph reader 设计。

## 候选 5：深化 Mode actions

### Files

- `st_mode.zig`：mode 分类和当前 `ModePlan`。
- `st_csi.zig`：CSI `h`/`l` 顶层 plan。
- `st.c`：`tsetmode()`。

### Problem

Mode 分类在 Zig，执行语义在 C。Zig 知道 mode number 属于哪个 kind，但 C 的 `tsetmode()` switch 仍持有 `xsetmode`、`tcursor`、`tswapscreen`、`tclearregion`、`tmoveato` 等动作顺序知识。

这导致 mode domain knowledge 跨 seam 泄漏：Zig 和 C 各知道一半事实，任一侧都不是完整 module。

### Solution

引入 `ModeExecPlan` 和 `ModeAction`。Zig 返回有序 action 列表，C 只作为 platform adapter 执行 action。

### Benefits

- **locality**：mode 语义集中在 `st_mode.zig`。
- **leverage**：新增 mode 只改一个 deep module。
- **test surface**：测试可以断言 action 顺序，不依赖端到端手测。
- **adapter clarity**：C 只保留副作用执行。

### Recommendation Strength

Worth exploring。

## 候选 6：收窄 adapter tests

### Files

- `st_line.zig`：selection/search adapter tests。
- `st_search.zig`：Search domain tests。
- `st_selection.zig`：Selection domain tests。

### Problem

部分测试被迫构造宽 extern interface，例如完整 `ZigSearchSnapshot`、`ZigSelectionSnapshot` 或多参数 `st_selected()`。但真实要验证的 behaviour 已经在 `st_search.zig` 和 `st_selection.zig` 的内部 module 中可以更直接测试。

当前 tests 跨过过宽 interface，降低可读性，也让测试维护负担随 adapter 字段增长而增长。

### Solution

把领域 behaviour 测试保留在对应 domain module；`st_line.zig` 的 adapter tests 收窄为 smoke tests，只验证 extern/domain/extern 转换不丢字段。

### Benefits

- **locality**：测试跟随 module。
- **interface is the test surface**：adapter tests 只测试 adapter interface。
- **less setup**：减少大 snapshot 构造。
- **change isolation**：domain 行为变化不要求修改 adapter 测试。

### Recommendation Strength

Speculative。

## 建议执行顺序

1. 先推进 Search 写模型所有权迁移。
2. 再拆分 `st_line.zig` 中的 Search adapter。
3. 顺手删除低风险 pass-through exports。
4. 等 Search/adapter 迁移稳定后，再设计 Selection snap 的 deeper interface。
5. 最后处理 Mode actions 和 adapter tests。

这个顺序的理由是：先处理项目文档已经确认的迁移主线，避免在 Search 所有权尚未稳定前重排太多 adapter seam。
