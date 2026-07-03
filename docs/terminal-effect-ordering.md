# Terminal Effect Ordering

## 目标

本文档把 terminal 行为中强依赖副作用顺序的边界显式化，用作后续把 `st.c` / `x.c` 拆成 Zig owner 与 C platform shim 时的迁移护栏。

核心原则：字段最终值相同不等于行为等价。凡是中间状态会被 draw、scroll、delete、selection、cursor 或 platform effect 立即消费的路径，都必须保留原有提交顺序，或把顺序升级为显式 transaction。

## 分类规则

### 必须原子提交

这些动作不能拆成多个独立 planner 字段由 C 分散消费。若迁移到 Zig，必须作为单个 transaction 返回，或继续保留当前 C commit helper。

| 边界 | 原子动作 | 证据 | 迁移约束 |
| --- | --- | --- | --- |
| graphic putc commit | `setdirty(y,y)` -> `lastc = u` -> `moveto(next_x,y)` 或 `state |= CURSOR_WRAPNEXT` | `st_commit_putc.h:24`, `st.c:2696`, `docs/reports/20260702-copy-delete-root-cause.md:19` | 禁止重新拆成 `mark_dirty`、`advance`、`cursor_state_bits` 分开消费 |
| glyph write + dirty | `st_tsetchar(...)` 后立即 `term.dirty[y] = 1` | `st.c:1786` | glyph 修改与 dirty 标记必须同拍可见 |
| screen swap + full dirty | `term.line` / `term.alt` 交换后立即切 mode 并 `tfulldirt()` | `st.c:1569` | 交换后的画面必须整体重绘，不能只返回普通 state update |
| platform effect list application | 按 `ZigPlatformEffectList` 原始顺序逐条执行，遇到终止型 effect 立即停止 | `st.c:2120` | effect list 是有序脚本，不是可重排集合 |

### 必须先后执行

这些动作可以由 Zig 产生 ordered step / effect list，但 C 必须按返回顺序执行，不能排序、合并或延后其中一步。

| 路径 | 必须顺序 | 证据 | 顺序原因 |
| --- | --- | --- | --- |
| `tputc()` graphic path | decode -> route -> optional print -> STR/control/ESC 先处理 -> selection clear -> wrapnext newline -> overflow newline -> `st_tputcwrite` -> `tcommitputcwrite` | `st.c:2731`, `st.c:2750`, `st.c:2787`, `st.c:2843`, `st.c:2859` | newline 后必须重新读取 `term.line[term.c.y][term.c.x]`；commit 依赖 write result |
| STR collection | apply first -> grow buffer -> retry append -> finish 或 abort | `st.c:2750` | grow 后才能 retry append；finish 会跳回 control check |
| ESC flow | write CSI byte -> parse CSI -> handle CSI / define charset / DEC test / ESC handle -> finish esc writeback | `st.c:2801` | `csihandle()` 依赖 `csiparse()` 后的 `csiescseq` 状态 |
| reset | `termapplystateupdate` -> reset tabs -> 两轮 move home / save cursor / clear / swap screen | `st.c:1539` | reset 同时影响 normal/alt screen，双屏顺序不可交换 |
| scroll transaction | optional history swap -> scrollback update -> clear/dirty -> line pointer swap loop -> selection scroll | `st.c:1618` | pointer swap、dirty range、selection 坐标都依赖前序状态 |
| resize transaction | slide/free/memmove -> realloc containers -> hist resize/fill -> row realloc/alloc -> tabs grow -> dimension writeback -> scroll/cursor reset -> 双屏 clear/swap/load cursor | `st.c:2891`, `docs/zig-architecture.md:76` | resize 是资源和显示状态混合 transaction，不允许只按 ordered step 字段等价判断安全 |
| clear region | normalize rect -> per row dirty -> selected check / `selclear()` -> clear glyph | `st.c:1793` | selection 与 dirty 都消费被清理前后的 line 状态 |
| draw frame | search scan -> dirty region draw -> cursor draw -> finish draw -> IME spot | `docs/architecture-flow.md:237`, `x.c:1549`, `x.c:1648`, `x.c:1685` | cursor draw 会重绘旧 cursor 行；finish draw 才把 buffer copy 到 window |
| OSC/platform string effects | decode clipboard -> set selection -> copy clipboard；set color/reset color -> redraw | `st.c:2146` | 后续 effect 依赖前序解码结果或 color failure 标记 |
| backspace | cursor state/x/y 写回 -> optional dirty range | `st.c:2624` | dirty range 由 backspace plan 计算，必须跟随同一次 cursor 写回消费 |
| focus color reload | focus flag/window mode/urgency/focus-report -> `xloadcols()` -> `tfulldirt()` | `x.c:1749` | 颜色资源重载后必须全量标脏，避免下一帧用旧颜色绘制 |
| RIS reset | `treset()` -> `resettitle()` -> `xloadcols()` | `st.c:2668` | RIS 同时重置 terminal state、窗口标题和颜色资源，不能重排跨资源副作用 |

### 只是纯决策

这些逻辑可以继续迁入 Zig struct 或保留 Zig plan。它们不得直接执行 C 全局写入、系统调用、X11、PTY、clipboard 或 heap ownership 操作。

| 决策 | 当前形式 | C 消费职责 |
| --- | --- | --- |
| 输入 route / print gate | `st_inputstepplan(...)` | C 选择 STR/control/ESC/graphic 分支并执行副作用 |
| STR collect transaction | `ZigStrCollectTransaction` | C 执行 `xrealloc`、`memcpy`、`strescseq.len` 写回 |
| ESC/control action 分类 | `ZigInputControlPlan`、`ZigInputEscPlan`、`ZigInputEscFlowPlan` | C 执行 tab、backspace、linefeed、bell、CSI parse/handle 等动作 |
| putc prepare | `clear_selection`、`wrapnext_newline`、`overflow_newline` | C 执行 `selclear()`、`tnewline()` 并重新取 glyph 指针 |
| cursor clamp / newline / reverse index | `ZigTermCursorPlan` | C 经 `termapplycursorplan()` 写回 cursor，必要时触发 scroll |
| CSI 顶层分类 | `ZigCsiExecPlan` | C 调用 `tapply*`、`tsetmode`、`tsetattr`、`xsetcursor` |
| mode / attr / light / tab 决策 | `ZigModePlan`、`ZigAttrUpdate`、`ZigLightPlan` | C 执行真实 bit write、tab 数组写入、platform mode effect |
| selection 状态决策 | `ZigSelectionStateResult` | C 写回 `sel`、dirty、clear、normalize 后续动作 |
| search scan / edit / jump 决策 | `SearchModel` 与 `st_search*` plans | C 执行 realloc、memmove、match 数组写入、redraw、jump scroll |
| line/history 坐标决策 | `ST_ZIG_TERM_LINE_READ_VIEWPORT_Y` / `FLAT_HISTORY_Y` / `RING_OFFSET` | C 按返回 `{hist,index}` 读取 `term.hist[]` 或 `term.line[]` |

### 只能留在 C executor

这些动作当前直接操作 C 持有的资源、平台对象或内存所有权。除非对应 owner 明确迁移，否则不能迁到 Zig 内部状态机。

| 动作 | 原因 | 证据 |
| --- | --- | --- |
| `term.line` / `term.hist` / `term.alt` 指针交换、realloc、free | C 持有 line/history ownership | `st.c:1647`, `st.c:1675` |
| dirty 数组写入 | `term.dirty` 仍是 C 全局数组 | `st.c:1499`, `st.c:1788`, `st.c:1805` |
| cursor / mode / charset / tabs / scroll region 最终写回 | `term` 标量 owner 仍在 C | `st.c:1720` |
| `tmoveto()` / `tmoveato()` / `tnewline()` | 可能触发 cursor state、origin mode、scroll transaction | `st.c:1708`, `st.c:1777` |
| `tclearregion()` | 同时读 selection、写 dirty、改 glyph | `st.c:1793` |
| heap mutation | `xmalloc`、`xrealloc`、`free`、`memmove`、`memcpy` 生命周期仍在 C | `st.c:2762`, `st.c:1675` |
| PTY IO | `cmdfd`、`write()`、`pselect()` 仍由 C 持有 | `st.c:1426` |
| X11/Xft/IME/window draw | X11 display/window/font resources 由 `x.c` 持有 | `x.c:1549`, `x.c:1648`, `x.c:1685` |
| clipboard / title / color platform calls | X selection、WM properties、color resources 由 C/X11 持有 | `x.c:1635`, `st.c:2146` |
| fork/pipe/exec/signal | OS process resources 与 fd 由 C executor 管理 | `st.c:2376` |
| selection scroll result apply | `selectionapplyscrollresult()` 的 state-only 分支不主动 dirty，调用者必须已覆盖 scroll/dirty effect | `st.c:559`, `st.c:1618`, `st.c:1578` |

## 放大器路径

这些路径常常不是 root cause，但会放大前面留下的坏状态。调试显示类 bug 时，应优先找首次制造坏状态的边界。

| 放大器 | 会消费的坏状态 | 证据 |
| --- | --- | --- |
| `drawregion()` / `xdrawline()` | 错误 glyph、dirty、selection/search highlight | `x.c:1648` |
| `xdrawcursor()` | 错误 cursor、旧 cursor 行、selection/search 状态 | `x.c:1549` |
| scroll / resize | 错误 line pointer、dirty、selection scroll | `st.c:1618`, `st.c:2891` |
| delete / clear | 错误 cursor 和 line 内容 | `st.c:1793`, `st.c:1815` |
| 光标移动 | 错误 `CURSOR_WRAPNEXT` 或 cursor state | `st.c:1708` |

## 迁移检查表

改动上述路径前必须逐项回答：

1. 这个改动是否把一个原子提交拆成多个字段？如果是，停止，改成 transaction。
2. 这个 effect list 是否保持了原顺序？如果不能证明，补测试或保留旧 executor。
3. 这个逻辑是否只是纯决策？如果不是，不能直接迁入 Zig owner。
4. 这个动作是否触碰 C 持有的资源 ownership？如果是，必须先有明确 owner migration issue。
5. 是否存在中间状态会被 draw、scroll、selection、cursor、delete 立即消费？如果是，必须验证时序等价，而不是只验证字段等价。
6. 自动化测试是否覆盖行为？如果没有，至少运行对应手测 checklist，并在 issue 中记录。

## 已知回归 checklist

`graphic putc commit` 相关手测保留在 `docs/reports/20260702-copy-delete-root-cause.md:119`，迁移 `tputc()`、dirty、cursor、draw、delete、wrap 时必须复用。
