# 2026-07-02 copy/delete 显示异常根因复盘

## 现象

- 终端里会先偶发一次“上一行内容被复制到当前行”
- 之后即使只移动光标，错误内容也会继续增殖
- 再做删除时，只是在删除已经被错误复制出来的内容，最初那次错误写入并没有被真正清掉

## 结论

- 根因不在 `scroll`、`draw`、`resize` 这些后续放大器本身
- 根因在 `tputc()` 图形字符写入尾段的状态提交时机被 `e048c7c5` 改坏
- 更具体地说，是 `dirty` 标记与 `CURSOR_WRAPNEXT` 的提交，不再沿用旧版“单次写入原子落地”的语义

命中修复的修改位于：`st.c:2787`

## 根因细化

正常分支 `8ea88fe7` 的图形字符写入尾段，本质上是一个紧凑的原子动作：

1. `st_tputcwrite(...)` 写 glyph
2. 立刻根据 `write.advance` 判断是否 `tmoveto(...)`
3. 当前行立刻标 dirty
4. 如果不能继续前进，立刻 `term.c.state |= CURSOR_WRAPNEXT`

坏提交 `e048c7c5` 把这段语义拆成了 planner + executor 两层：

- Zig 侧 `PutcStep.plan()` 返回
  - `mark_dirty`
  - `advance`
  - `cursor_state_mask`
  - `cursor_state_bits`
- C 侧再逐项消费这些字段

相关 planner 在：`st_setchar.zig:286`

问题不在这些字段“静态上不正确”，而在它们把原来一次提交的写入结果拆成了多个彼此独立的副作用。对 terminal 这种强依赖中间态时序的代码，这种“看起来等价”的改写并不等价。

一旦首次写入时 `dirty` 或 `CURSOR_WRAPNEXT` 没按旧语义在同一个时序点落地，就会出现：

- glyph 内容已经变了
- 但 dirty / cursor state / redraw 消费点看到的是另一拍的状态

这样后面的 `drawregion()`、`xdrawcursor()`、光标移动、删除、scroll，只是在持续消费第一次写坏后留下的脏状态，所以表现成“光标一动就继续复制”。

## 为什么前面几轮没有修好

本次排障先后回退过：

1. `tapplyscrollplan()`
2. `draw()` / `drawregion()`
3. `tsetchar()` / `tclearregion()` 的 dirty 写入
4. `tresize()`

这些改动都更像是在修“错误状态被如何放大”。

但真正的首次错误写入发生在 `tputc()` 尾段，所以：

- scroll 是放大器
- draw 是放大器
- resize 可能是放大器
- delete 是放大器

都不是最初把状态写坏的地方。

## 这次真正生效的修复

修复保留了 `st_inputstepplan(...)` 的顶层路由能力：

- STR 路由
- control 路由
- ESC 路由
- `wrapnext_newline`
- `overflow_newline`

只把图形字符写入后的“状态消费方式”恢复到旧语义：

- 继续调用 `st_tputcwrite(...)`
- 当前行直接 `tsetdirt(term.c.y, term.c.y)`
- 继续用 `write.advance` / `write.next_x`
- `advance != MOVE` 时直接 `term.c.state |= CURSOR_WRAPNEXT`

也就是说，保留了新主线的路由收口，但撤销了这一步对“写入结果提交时机”的过度拆分。

## 这次修复学到的心得

### 1. 终端渲染代码里，“语义等价”不等于“时序等价”

- 把一个动作拆成 plan 字段再逐项执行，在业务代码里常常没问题
- 但在 terminal 这种依赖 glyph、dirty、cursor、wrap 状态同拍收敛的代码里，拆分动作很容易破坏隐含 invariant

### 2. “只移动光标还会继续变多”通常说明根因早于 draw

- 如果移动光标只是触发放大，说明 draw/scroll/delete 很可能只是消费了先前留下的坏状态
- 这类现象优先查首次写入点，而不是优先查重绘点

### 3. 回退式二分要优先找“首次制造脏状态”的边界

- `scroll`、`draw`、`resize` 这些边界很显眼，但不一定是 root cause
- 更有效的问题是：哪一层第一次让状态进入“后续任何 redraw 都会出错”的坏区间

### 4. 架构文档里的“已收口”描述必须持续接受真实 bug 校验

- 这次手测结果已经证明：
  - `graphic` 写入路径并没有完全安全地收口到 `ZigPutcStepPlan`
  - `dirty marking 已集中` 这种表述也需要更谨慎
- 文档里的“收口完成”只能表示当前设计目标，不代表行为已经被真实交互充分验证

### 5. 对显示类 bug，build/test 全绿只能证明 ABI 正常，不能证明渲染正确

- 本次多轮 `zig build test`、`zig build abi-check`、`zig build` 都通过
- 但真正给出方向的是手测反馈，而不是自动化结果

## 后续建议

- 在没有更强交互测试前，不要再次把 `tputc()` 图形写入尾段机械地拆成独立的 dirty/cursor-state effect
- 如果未来还要继续推进 `Input/TermState owner`，优先把“单次图形写入提交”定义成一个不可拆的更深模块边界，而不是继续暴露细粒度字段给 C executor
