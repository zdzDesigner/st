# C Responsibility Map

> [同步]: docs/terminal-effect-ordering.md, docs/zig-architecture.md, docs/architecture-flow.md
> [定位]: 把 st.c / x.c 的函数按 owner struct 归类，标注迁移决策所需字段。作为 C shim 收缩和 Zig owner struct 迁移的护栏文档。
> [输入]: terminal-effect-ordering.md 四类护栏（必须原子提交、必须先后执行、纯决策、只能留在 C executor）
> [输出]: 覆盖主流程函数和高风险 seam 的 owner 分类表

## Owner 词汇

| Owner | 职责概要 | 全局状态 |
| --- | --- | --- |
| **Input** | PTY/X11 输入读取、UTF-8 decode、顶层路由（STR/control/ESC/graphic） | `buf`, `csiescseq`, `strescseq` |
| **EscapeMachine** | ESC/CSI/STR 收集、parse、action 分类、flow 编排 | `csiescseq`, `strescseq`, `term.esc` |
| **TerminalState** | 全局 term 标量读写：mode、charset、tabs、scroll region、dimensions | `term` 标量字段 |
| **Screen** | glyph 写入、dirty 标记、cursor 坐标、line/alt 渲染数据 | `term.line`、`term.alt`、`term.dirty`、`term.c` |
| **History** | history ring buffer、scrollback、histi/scr 指针 | `term.hist`、`term.histi`、`term.scr` |
| **Selection** | selection start/extend/normalize/snap/getsel | `sel` |
| **Search** | search query/input/matches/scan/jump/highlight | `search` |
| **Renderer** | X11 draw frame、glyph 渲染、cursor draw、search bar、IME spot | `xw`、`dc`、`win` |
| **Platform** | X11 资源、PTY fd、clipboard、title、color、fork/exec/signal、window mode | `xw.dpy`、`cmdfd`、`xsel` |

---

## 四类护栏引用

四类边界定义在 `docs/terminal-effect-ordering.md`：

1. **必须原子提交** (§11–§20): `graphic putc commit`、`glyph write + dirty`、`screen swap + full dirty`、`platform effect list application`。
2. **必须先后执行** (§22–§39): `tputc` graphic path、STR collection、ESC flow、reset、scroll transaction、resize transaction、clear region、draw frame、OSC/platform effects、backspace、focus color reload、RIS reset。
3. **只是纯决策** (§41–§56): 输入 route / print gate、STR collect transaction、ESC/control action 分类、putc prepare、cursor clamp、CSI 分类、mode/attr/light/tab 决策、selection 状态决策、search scan/edit/jump 决策、line/history 坐标决策。
4. **只能留在 C executor** (§58–§74): line/hist/alt 指针操作、dirty 数组写入、cursor/mode/charset/tabs/scroll 写回、`tmoveto`/`tmoveato`/`tnewline`、`tclearregion`、heap mutation、PTY IO、X11/Xft/IME、clipboard/title/color、fork/pipe/exec、selection scroll result apply。

以下函数按 owner 归类，并标注迁移决策所需字段。

---

## Input Owner

| 函数 | 文件 | 持有状态 | 执行副作用 | 可迁 Zig | 风险等级 | 前置验证 |
| --- | --- | --- | --- | --- | --- | --- |
| `ttyread()` | st.c:1365 | 否: 读 `cmdfd`，写 `buf` + `twrite` | 是: `read()` + `twrite()` | 否: PTY + `twrite` 是纯 C | 高 | ordering: STR > control > ESC |
| `twrite()` | st.c:2864 | 否: 遍历 `buf`，逐 char 调 `tputc` | 是: 调 `tputc` | 否: 是 Input→TerminalState 桥 | 中 | UTF-8 decode 已迁 Zig |
| `tputc()` | st.c:2716 | 否: 读取全局 term/esc/selected | 是: 写 line、dirty、cursor | 否: **必须原子提交** putc commit (§11) | **最高** | [原子护栏] §17; 20260702 report |
| `st_tputcwrite()` | st.c(st_zig.h:1219) | 否: 纯值→值 | 否 | **是**: 当前已是 Zig 侧 | 低 | 已迁 |
| `tcommitputcwrite()` | st.c:2710 | 否: 委托 `commit_putc()` 协议 | 是: `setdirty` + `moveto`/`wrapnext` | 否: 但协议可抽象 | 高 | **必须原子提交** (§17) |
| `st_inputstepplan()` | st.c(st_zig.h:1216) | 否: 纯决策 | 否 | **是**: 纯路由+collect | 低 | **只是纯决策** (§41) |
| `st_putcdecode()` | st.c(st_zig.h:1214) | 否 | 否 | **是**: UTF-8 编解码 | 低 | 已迁 |
| `st_twritecontrol()` | st.c(st_zig.h:1215) | 否 | 否 | **是**: caret/bracket 决策 | 低 | 已迁 |
| `ttywrite()` | st.c:1389 | 否 | 是: `kscrolldown` + `write()` | 否: PTY + mode read | 中 | `ZigIoEffectList` 已返回 plan |

## EscapeMachine Owner

| 函数 | 文件 | 持有状态 | 执行副作用 | 可迁 Zig | 风险等级 | 前置验证 |
| --- | --- | --- | --- | --- | --- | --- |
| `tcontrolcode()` | st.c:2618 | 否 | 是: 调 `inputapplycontrolplan` | 否: C 执行 tab/backspace/linefeed | 中 | decision 在 Zig (§43) |
| `inputapplycontrolplan()` | st.c:2567 | 否 | 是: `tputtab`/`tbackspace`/`tnewline`/`xbell`/`tstrsequence` | 否: 消费 Zig plan 但执行副作用 | 中 | [顺序护栏] §71 |
| `csiparse()` | st.c:1756 | 否: 写 `csiescseq` | 否 | **是**: 纯扫描 | 低 | 已迁 `st_csiparse` |
| `csihandle()` | st.c:2013 | 否 | 是: `tapply*/tsetmode/tsetattr` | 否: 执行 plan | **顺序护栏** (§31) | Zig plan 已返回 (§52) |
| `strhandle()` | st.c:2343 | 否: 读 `strescseq` | 是: `strapplyplan` → platform effects | 否: C 执行 platform | **顺序护栏** (§37) | platform effects 已有序 (§20) |
| `st_strparse()` | st.c(st_zig.h:1207) | 否 | 否 | **是** | 低 | 已迁 |
| `strparse()` | st.c:2357 | 否: 写 `strescseq` args | 否 | 部分: 边界扫描在 Zig | 低 | |
| `strapplyplan()` | st.c:2098 | 否 | 是: `platformapplyeffects` | 否 | 中 | [顺序护栏] §37 |
| `strreset()` | st.c:2456 | 否: 重置 `strescseq` | 是: `xrealloc` | 否: heap 操作 | 低 | `st_strresetplan` 已返回 size |
| `tstrsequence()` | st.c:2548 | 否: 写 `strescseq.type` / `term.esc` | 否 | **是**: 决策在 Zig | 低 | |
| `st_tstrsequence()` | st.c(st_zig.h:1208) | 否 | 否 | **是** | 低 | 已迁 |
| `eschandle()` | st.c:2642 | 否 | 是: `tstrsequence`/`tnewline`/`tcursor`/`treset`/`ttywrite` | 否: C 执行 | **顺序护栏** (§29) | decision 在 Zig |

## TerminalState Owner

| 函数 | 文件 | 持有状态 | 执行副作用 | 可迁 Zig | 风险等级 | 前置验证 |
| --- | --- | --- | --- | --- | --- | --- |
| `termapplystateupdate()` | st.c:1720 | 否: 写 `term` 标量 | 否 | **是**: 标量写回 plan | 中 | [只能留 C] §66 |
| `termapplycursorplan()` | st.c:1708 | 否: 写 `term.c` | 是: 可能触发 scroll | 部分: cursor plan 在 Zig | 中 | |
| `historyapplystateupdate()` | st.c:1749 | 否: 写 `term.scr`/`term.histi` | 否 | **是**: 标量写回 | 低 | |
| `tsetscroll()` | st.c:1884 | 否 | 否 | **是**: plan 在 Zig | 低 | |
| `tsetmode()` | st.c:2001 | 否: 调 `st_modeplan` + `termapplystateupdate` | 是: `platformapplyeffects` | 部分: decision 在 Zig | 中 | mode plan 已收口 (§82–83) |
| `tsetattr()` | st.c:1847 | 否 | 否 | 部分: `st_tsetattr` 已迁 | 低 | |
| `tmoveto()` | st.c:1777 | 否 | 否 (但通过 cursor plan) | 否: 是 C cursor helper | **顺序护栏** (§72) | [必须先后] §72 |
| `tmoveato()` | st.c:1768 | 否 | 否 | 否 | 中 | §67: 可能触发 scroll |
| `tnewline()` | st.c:1699 | 否 | 是: 可能 scroll | 否 | 中 | [必须先后] §72 |
| `treset()` | st.c:1539 | 否 | 是: multi-screen reset loop | 否: C 执行 step loop | **最高** | [必须先后] §30; `ZigResetExecPlan` |
| `tswapscreen()` | st.c:1569 | 否 | 是: 交换 `term.line`/`term.alt` + mode + `tfulldirt()` | 否: 必须原子提交 (§19) | **最高** | [必须原子] §19 |
| `tfulldirt()` | st.c:1522 | 否 | 是: dirty 写 | 否 | 低 | |
| `tsetdirt()` | st.c:1499 | 否 | 是: `term.dirty` 写 | 否 | 低 | |
| `redraw()` | st.c:2983 | 否 | 是: `tfulldirt` + `draw` | 否 | 低 | |

## Screen Owner

| 函数 | 文件 | 持有状态 | 执行副作用 | 可迁 Zig | 风险等级 | 前置验证 |
| --- | --- | --- | --- | --- | --- | --- |
| `tsetchar()` | st.c:1786 | 否: 写 `term.line[y][x]` | 是: glyph + dirty | 部分: `st_tsetchar` 已迁 | 高 | **原子提交** (§18) |
| `tclearregion()` | st.c:1793 | 否 | 是: dirty + selected + glyph | **否** | **最高** | [只能留 C] §68; 读 sel + 写 dirty |
| `tsetattr` | st.c:1847 | 否: 写 `term.c.attr` | 否 | 部分 | 低 | 归属见 TerminalState Owner |
| `tdeletechar()` | st.c:1815 | 否 | 是: `memmove` + `tclearregion` | 部分: plan in Zig | 中 | |
| `tinsertblank()` | st.c:1826 | 否 | 是: `memmove` + `tclearregion` | 部分 | 中 | |
| `tinsertblankline()` | st.c:1837 | 否 | 是: `tscrolldown` | 否 | 中 | |
| `tdeleteline()` | st.c:1842 | 否 | 是: `tscrollup` | 否 | 中 | |
| `tputtab()` | st.c:2520 | 否: 写 `term.c.x` | 否 | 部分: `st_tputtab` 已迁 | 低 | |
| `tdumpline()` | st.c:2498 | 否 | 是: `tprinter` + `utf8encode` | 部分: plan in Zig | 低 | |
| `tdump()` | st.c:2513 | 否 | 是: 逐行 dump | 否 | 低 | |
| `tdumpsel()` | st.c:2489 | 否 | 是: `getsel` + `tprinter` | 否 | 低 | |
| `tapplyerase()` | st.c:1891 | 否 | 是: `tclearregion` | 否 | 中 | |
| `tapplyedit()` | st.c:1910 | 否 | 是: dispatch edit ops | 否 | 中 | `ZigEditPlan` 已迁 |
| `st_tclearglyph()` | st.c(st_zig.h:1218) | 否 | 否 | **是** | 低 | 已迁 |
| `drawregion()` | st.c:2954 | 否 | 是: platform draw effects | 否 | 高 | [顺序护栏] §35 |
| `draw()` | st.c:2968 | 否 | 是: `xstartdraw` → platform effects | 否 | 高 | [顺序护栏] §35 |
| `st_drawexecplan()` | st.c(st_zig.h:1193) | 否 | 否 | **是** | 低 | 已迁 |
| `st_drawregiontransaction()` | st.c(st_zig.h:1194) | 否 | 否 | **是** | 低 | 已迁 |
| `tattrset()` | st.c:1497 | 否 | 否 | **是**: `st_tattrset` 已迁 | 低 | |
| `tsetdirtattr()` | st.c:1513 | 否 | 是: `tsetdirt` | 否 | 低 | |
| `tdectest()` | st.c:2537 | 否 | 是: 逐行 `tsetchar` | 否 | 低 | |

## History Owner

| 函数 | 文件 | 持有状态 | 执行副作用 | 可迁 Zig | 风险等级 | 前置验证 |
| --- | --- | --- | --- | --- | --- | --- |
| `tlinehist()` | st.c:443 | 否: 读 `term.hist` | 否 | **是**: `st_termlinereadplan` 已迁 | 低 | 已迁 |
| `tlineviewport()` | st.c:458 | 否: 读 `term.line` | 否 | **是**: `st_termlinereadplan` 已迁 | 低 | 已迁 |
| `searchhistline()` | st.c:1039 | 否: 读 `term.hist` | 否 | **是** | 低 | |
| `tscrollup()` / `tscrolldown()` | st.c:1611 / 1604 | 否 | 是: `tapplyscrollplan` | 否: C 执行 pointer ops | 高 | [顺序护栏] §32 |
| `tapplyscrollplan()` | st.c:1618 | 否 | 是: hist swap + dirty + pointer loop | **否** | **最高** | [原子+顺序] §19 §32 |
| `linepointerswaphistory()` | st.c:1647 | 否: 读/写 `term.hist`/`term.line` | 是: 指针交换 | **否** | **最高** | [只能留 C] §64 |
| `linepointerswaprow()` | st.c:1655 | 否: 读/写 `term.line` | 是: 指针交换 | **否** | 高 | [只能留 C] §64 |
| `linepointerfreerowpair()` | st.c:1663 | 否 | 是: `free()` | **否** | 高 | [只能留 C] §64 |
| `linepointermemmoverows()` | st.c:1668 | 否 | 是: `memmove()` | **否** | 高 | [只能留 C] §64 |
| `linepointerreallocarrays()` | st.c:1675 | 否 | 是: `xrealloc()` | **否** | 高 | [只能留 C] §64 |
| `linepointerreallocrowpair()` | st.c:1682 | 否 | 是: `xrealloc()` | **否** | 高 | [只能留 C] §64 |
| `linepointerallocrowpair()` | st.c:1687 | 否 | 是: `xmalloc()` | **否** | 高 | [只能留 C] §64 |
| `kscrolldown()` / `kscrollup()` | st.c:1578 / 1591 | 否 | 是: scr/selscroll/tfulldirt | 部分: plan 在 Zig | 中 | `ZigKScrollPlan` 已返回 |
| `selscroll()` | st.c:1692 | 否 | 是: `selectionapplyscrollresult` | 部分: plan 在 Zig | 中 | |
| `tresize()` | st.c:2891 | 否 | 是: slide/free/realloc/hist/clear/swap | **否** | **最高** | [顺序护栏] §33; 混合 resource+display |
| `st_tresizeexecplan()` | st.c(st_zig.h:1201) | 否 | 否 | **是** | 低 | 已迁但顺序不能仅依赖 plan (20260702 report) |
| `ttyresize()` | st.c:1481 | 否 | 是: `ioctl(TIOCSWINSZ)` | **否** | 中 | |
| `termapplydirtyrange()` | st.c:1506 | 否 | 是: `term.dirty[i] = 1` | 否 | 低 | |

## Selection Owner

| 函数 | 文件 | 持有状态 | 执行副作用 | 可迁 Zig | 风险等级 | 前置验证 |
| --- | --- | --- | --- | --- | --- | --- |
| `selinit()` | st.c:435 | 否: 写 `sel` | 否 | 部分: plan 在 Zig | 低 | |
| `selstart()` | st.c:473 | 否 | 是: `selclear` + `selectionapplyresult` + `selnormalize` + `tsetdirt` | 部分: plan 在 Zig | 中 | `ZigSelectionStateResult` 已返回 |
| `selextend()` | st.c:485 | 否 | 是: `selectionapplyresult` + `selnormalize` | 部分 | 中 | |
| `selnormalize()` | st.c:501 | 否: 读 `sel`/`tlinelen` | 是: `selectionapplybounds` + snap | 部分 | 中 | SnapWordIterator 两阶段已迁 |
| `selsnappoint()` | st.c:1075 | 否 | 否: 回调 C 读 glyph | **是**(decision) | 中 | SnapWordIterator (§105) |
| `selclear()` | st.c(st_zig.h:1227) | 否 | 是: `selclearplan` | 部分: plan in Zig | 低 | |
| `selected()` | st.c:566 | 否 | 否 | **是**: `st_selected` | 低 | 已迁 |
| `getsel()` (st.h:134) | st.c:1148 | 否 | 是: malloc + UTF-8 encode | **否**: 资源操作 | 高 | [只能留 C] §64 |
| `mousesel()` | x.c:365 | 否 | 是: `selextend` + `setsel` | 否: X11 event | 中 | |
| `selectionsnapshot()` | st.c:517 | 否: 读 `sel` | 否 | **是**: 纯快照 | 低 | |
| `selectionapplystate()` | st.c:534 | 否: 写 `sel` | 否 | 部分: update 在 Zig | 中 | |
| `selectionapplybounds()` | st.c:546 | 否: 写 `sel.nb/ne` | 否 | 部分: update 在 Zig | 中 | |
| `selectionapplyresult()` | st.c:553 | 否 | 是: dirty | 否 | 中 | |
| `selectionapplyscrollresult()` | st.c:559 | 否 | 是: clear or state | 否 | 中 | [只能留 C] §74 |
| `selectioncopyline()` | st.c:1185 | 否 | 是: UTF-8 encode | 否 | 低 | |
| `st_getselexecplan()` | st.c(st_zig.h:1253) | 否 | 否 | **是** | 低 | 已迁 |
| `st_selectionextracttransaction()` | st.c(st_zig.h:1254) | 否 | 否 | **是** | 低 | 已迁 |

## Search Owner

| 函数 | 文件 | 持有状态 | 执行副作用 | 可迁 Zig | 风险等级 | 前置验证 |
| --- | --- | --- | --- | --- | --- | --- |
| `searchsnapshot()` | st.c:761 | 否: 读 `search` | 否 | **是**: 纯快照 | 低 | |
| `searchapplyupdate()` | st.c:763 | 否: 写 `search` 标量 | 否 | **是**: update 在 Zig | 中 | |
| `searchapplyresourceeffect()` | st.c:765 | 否 | 是: `free()` query/matches | **否** | 中 | heap mutation §69 |
| `searchapplyvieweffect()` | st.c:776 | 否 | 是: `searchjump` + `redraw` | **否** | 中 | effect 消费 |
| `searchapplyfloweffect()` | st.c:783 | 否 | 是: `set` 或 view | **否** | 中 | |
| `searchscan()` | st.c:958 | 否 | 是: `searchapplymatchestransaction` | 否 | 中 | |
| `searchapplymatchestransaction()` | st.c:962 | 否 | 是: loop + array write | **否** | 高 | scan transaction: C 写 matches |
| `searchscanline()` | st.c:998 | 否 | 是: `xrealloc` + array write | **否** | 高 | C 写 `search.matches` |
| `searchset()` | st.c:954 | 否 | 是: query replace + scan | 否 | 高 | [顺序护栏]: alloc→decode→scan→jump |
| `searchapplycursor()` | st.c:894 | 否 | 是: delete + memmove | 否 | 中 | |
| `searchapplystate()` | st.c:947 | 否 | 是: clear/commit/cancel | 否 | 中 | |
| `searchprompt()` | st.c:643 | 否 | 是: alloc + redraw | 否 | 中 | |
| `searchinput()` | st.c:661 | 否 | 是: insert + `set` | 否 | 中 | |
| `searchjump()` | st.c:1054 | 否 | 是: `term.scr` + `tfulldirt` | 部分 | 中 | |
| `searchmatch()` / `searchcurrent()` | st.c:568 / 578 | 否 | 否 | **是**: plan in Zig | 低 | |
| `searchnext()` / `searchprev()` | st.c:607 / 625 | 否 | 是: `searchscan` + `searchjump` + `redraw` | 部分 | 中 | |
| `searchclear()` | st.c:588 | 否 | 是: `searchresetstate` + `redraw` | 否 | 低 | |
| `searchresetstate()` | st.c:886 | 否 | 是: free + memset | **否** | 中 | heap mutation |
| `searchbaractive()` | st.c:596 | 否 | 否 | **是**: 纯读 | 低 | 已回退 C executor |
| `searchinputactive()` | st.c:594 | 否 | 否 | **是**: 纯读 | 低 | 已回退 C executor |
| `searchinputtext()` | st.c:603 | 否 | 否 | **是**: 纯读 | 低 | |
| `searchinputcursor()` | st.c:605 | 否 | 否 | **是**: 纯读 | 低 | |
| `st_search*` ABIs | st_zig.h | 否 | 否 | **是** | 低 | 已下沉 `st_search.zig` |

## Renderer Owner (x.c)

| 函数 | 文件 | 持有状态 | 执行副作用 | 可迁 Zig | 风险等级 | 前置验证 |
| --- | --- | --- | --- | --- | --- | --- |
| `xdrawline()` | x.c:1648 | 否: 读 `term.line` / `search` | 是: Xft draw | **否**: X11 资源 | **高** | [放大器] §83 |
| `xdrawcursor()` | x.c:1549 | 否 | 是: Xft draw + redraw old line | **否** | **高** | [放大器] §84 |
| `xdrawglyph()` | x.c:1480 | 否 | 是: Xft draw | **否** | 中 | |
| `xdrawsearchbar()` | x.c:1528 | 否 | 是: Xft draw | **否** | 低 | |
| `xdrawsearchtext()` | x.c:1489 | 否 | 是: `xdrawglyph` 循环 | **否** | 低 | |
| `xfinishdraw()` | x.c:1685 | 否 | 是: `XCopyArea` + `xdrawsearchbar` | **否** | **高** | [顺序护栏] §35 |
| `xstartdraw()` | x.c:1646 | 否 | 否 | **是**: MODE_VISIBLE check | 低 | |
| `xximspot()` | x.c:1692 | 否 | 是: XIC call | **否** | 低 | [顺序护栏] §35 |
| `xmakeglyphfontspecs()` | x.c:1200+ | 否 | 是: font lookup | **否** | 低 | |
| `xdrawglyphfontspecs()` | x.c:1350+ | 否 | 是: Xft draw | **否** | 中 | |
| `xclear()` | x.c:779 | 否 | 是: XftDrawRect | **否** | 低 | |

## Platform Owner (x.c)

| 函数 | 文件 | 持有状态 | 执行副作用 | 可迁 Zig | 风险等级 | 前置验证 |
| --- | --- | --- | --- | --- | --- | --- |
| `xinit()` | x.c:1098 | 否: 初始化所有 X | 是: XOpenDisplay, XCreateWindow, ... | **否** | 高 | 资源生命周期 |
| `xloadcols()` | x.c:736 | 否 | 是: XftColorAlloc | **否** | 中 | [顺序护栏] §38: focus color reload |
| `xloadfonts()` | x.c:893 | 否 | 是: Fc/Font load | **否** | 中 | |
| `xsetcolorname()` | x.c:762 | 否 | 是: XftColorFree + Alloc | **否** | 中 | [顺序护栏] §37 |
| `xsettitle()` | x.c:1635 | 否 | 是: WM property set | **否** | 低 | |
| `xseticontitle()` | x.c:1624 | 否 | 是: WM property set | **否** | 低 | |
| `xsetmode()` | x.c:1719 | 否 | 是: win.mode write | 部分: mode check | 低 | |
| `xsetcursor()` | x.c:1726 | 否 | 是: win.cursor write | **是**: 纯验证 | 低 | |
| `xsetpointermotion()` | x.c:1713 | 否 | 是: XChangeWindowAttributes | **否** | 中 | |
| `xbell()` | x.c:1743 | 否 | 是: XkbBell | **否** | 低 | |
| `xclipcopy()` | x.c:684 | 否 | 是: XSetSelectionOwner | **否** | 中 | |
| `setsel()` / `xsetsel()` | x.c:636 / 647 | 否 | 是: XSetSelectionOwner | **否** | 中 | |
| `clipcopy()` | x.c:278 | 否 | 是: XSetSelectionOwner | **否** | 中 | |
| `selnotify()` | x.c:502 | 否 | 是: XGetWindowProperty → ttywrite/searchinput | **否** | 高 | 含 search/paste 路由 |
| `selrequest()` | x.c:588 | 否 | 是: XChangeProperty / XSendEvent | **否** | 中 | |
| `kpress()` | x.c:1825 | 否 | 是: XmbLookupString + search dispatch / ttywrite | **否** | **高** | 搜索模式路由核心 |
| `bpress()` / `brelease()` / `bmotion()` | x.c:459 / 649 / 660 | 否 | 是: mouse selection / mouse report | **否** | 中 | |
| `mousereport()` | x.c:380 | 否 | 是: `ttywrite` mouse escape | **否** | 中 | |
| `focus()` | x.c:1749 | 否 | 是: IME + ttywrite + xloadcols + tfulldirt | **否** | 高 | [顺序护栏] §38: focus color reload |
| `resize()` | x.c:1955 | 否 | 是: `cresize` | **否** | 中 | |
| `cresize()` | x.c:670 | 否 | 是: `tresize` + `xresize` + `ttyresize` | **否** | **高** | resize transaction §33 |
| `xresize()` | x.c:687 | 否 | 是: X pixmap + specbuf realloc | **否** | 中 | |
| `run()` | x.c:1962 | 否 | 是: select loop + XEvent dispatch + draw | **否** | 最高 | 主 event loop |
| `main()` | x.c:2115 | 否 | 是: XOpenDisplay + tnew + xinit + run | **否** | 高 | 启动入口 |
| `ttynew()` | st.c:1307 | 否 | 是: openpty + fork + exec | **否** | **最高** | fork/pipe/exec §73 |
| `sigchld()` | st.c:1200+ | 否 | 是: signal handler | **否** | 中 | |
| `externalpipe()` | st.c:2376 | 否 | 是: pipe + fork + execvp + xwrite | **否** | 高 | fork/pipe/exec §73 |
| `sendbreak()` | st.c:2465 | 否 | 是: `tcsendbreak` | **否** | 低 | |
| `resettitle()` | st.c:2952 | 否 | 是: `xsettitle` | **否** | 低 | [RIS] §39 |

---

## 高风险 Seam 汇总表

| Seam | 涉及函数 | Ordering 约束 | 迁移策略 |
| --- | --- | --- | --- |
| **graphic putc commit** | `tputc` → `tcommitputcwrite` | **必须原子** (§17) | 不可拆；保留当前 commit 协议 |
| **scroll transaction** | `tapplyscrollplan` + line pointer ops | **必须先后** (§32) | Zig plan → C executor；不迁 pointer ops |
| **resize transaction** | `tresize` | **必须先后** (§33) | Zig execplan 提供范围；C 执行顺序不可替换 |
| **draw frame** | `draw` → platform effects | **必须先后** (§35) | 保留 search scan → region draw → cursor → finish → IME |
| **screen swap** | `tswapscreen` | **必须原子** (§19) | 交换+dirty 不可拆 |
| **RIS reset** | `eschandle(RIS)` | **必须先后** (§39) | treset → resettitle → xloadcols 不可重排 |
| **focus color reload** | `focus(FocusIn/Out)` | **必须先后** (§38) | xloadcols → tfulldirt 不可分 |
| **selection → clipboard** | `mousesel` → `setsel` → XSel | 依赖 getsel 输出 | X11 资源不迁 |

---

## 迁移护栏检查表

对每个 candidate owner 迁移，必须回答 `docs/terminal-effect-ordering.md` §89–97 六问：

1. 是否把一个原子提交拆成多个字段？
2. effect list 是否保持原顺序？
3. 是否只是纯决策？
4. 是否触碰 C 持有的资源 ownership？
5. 是否存在中间状态会被 draw/scroll/selection/cursor/delete 立即消费？
6. 自动化测试是否覆盖行为？

## 迁移优先级建议

| 优先级 | Owner | 理由 | 备注 |
| --- | --- | --- | --- |
| 1 | **Search** | 状态独立、Zig 已有大量纯逻辑、ABI 已收薄 | 当前首选（zig-architecture §97） |
| 2 | **Selection** | snapshot 已定版、snap loop 两阶段已迁 | `selsnap` 仍依赖 `TLINE` 读 glyph |
| 3 | **EscapeMachine** | STR/ESC decision 已部分迁 Zig | 仍需 C 执行 buffer grow / xrealloc |
| 4 | **TerminalState** | state update plan 已集中 | dirty/cursor/WRAPNEXT 提交时机敏感 |
| 5 | **Input** | route decision 已迁 | graphic write commit 是最高风险边界 |
| 6 | **History** | 标量写回已集中到 `HistoryStateUpdate` | `term.hist` ownership 不能迁 |
| 7 | **Screen** | dirty/glyph write 是最高频 | `tsetchar` + dirty 原子提交不可拆 |
| 8 | **Platform** | X11/PTY/clipboard 资源生命周期 | 最后评估，前三阶段稳定后 |

---

## 总结

| 改动边界 | 目标文件 | 已/拟修改点 | 预期验证命令 | 已知风险 |
| --- | --- | --- | --- | --- |
| 责任地图文档化 | `docs/c-responsibility-map.md` (本文件) | 新增 | `zig build abi-check && zig build test && zig build` | 仅文档，无行为变更 |
| 后续 C shim 收缩 | st.c / x.c (未动) | 基于本地图选择单一 owner 切入 | 每批迁移后跑 `zig fmt && zig build test && zig build && timeout 5 ./zig-out/bin/st` | 不可触碰四类护栏中的边界 |

**实际修改文件**: `docs/c-responsibility-map.md` (新增)
**未修改行为代码**: st.c / x.c / st.h / win.h / st_zig.h 均未修改
