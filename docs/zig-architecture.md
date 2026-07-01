# Zig 架构边界

## 目标

Zig 代码按领域职责组织，避免把 `st.c` 中的 `if` 分支直接搬成长期 ABI helper。短期目标是把 C 收缩成极薄 shim；中期目标是让 Zig 接管状态模型和主线决策，C 只保留平台桥接、系统调用、资源生命周期和过渡 ABI。

## 当前边界

- C 当前负责全局状态、`TLINE(...)`、内存所有权、X11、PTY、clipboard、IO 和实际副作用执行。
- Zig 内部模块负责值类型模型、状态机、范围计算、编辑计划、匹配计划和可单元测试的纯逻辑。
- Zig 内部模块优先用领域 `struct` 管理状态，并把响应行为放在方法上；裸函数只保留为 adapter 兼容入口或无状态工具。
- `export fn` 所在文件负责 C ABI adapter：把 C 标量、extern struct 和指针切片转换成 Zig 内部类型。
- 内部模块不直接暴露给 C，不读取 `term`、`sel` 等 C 全局变量。

## 目标边界

- Zig 逐步接管 `term`、`sel`、`search` 等状态模型的读写和主线决策。
- C 逐步收缩为极薄 shim，只保留 X11、PTY、clipboard、系统 IO、资源生命周期、启动 glue 和必要的兼容 ABI。
- `st_zig.h` 从长期边界降级为过渡兼容层；随着状态所有权迁移，导出符号数量应持续减少。
- 需要读取 C 全局状态才能做判断的逻辑，应优先改造成“C 提供快照 / Zig 返回新状态 + effect plan”的形态，而不是继续扩大 C executor。

## 最终目标路线

- **阶段 1: STR/Input owner**：先把 STR collection、parse、handle 的状态决策迁入 Zig；C 继续持有 `strescseq.buf`、执行 `xrealloc` 和 X11/clipboard 副作用，直到 buffer transaction 已完全稳定。
- **阶段 2: Line/History owner**：在 STR/Input 稳定后，单独设计 `term.line`、`term.alt`、`term.hist`、`term.histi` 的 snapshot/update/effect seam；不与 platform effect 同批迁移。
- **阶段 3: TermState owner**：把 cursor、dirty、mode、scroll、reset、resize 的标量状态收敛为统一 term state update；C 只负责执行 clear/draw/swap 等 effect。
- **阶段 4: Platform shim**：最后再评估 X11、PTY、clipboard、IO 的 effect ordering；只有状态 ownership 稳定后才缩减平台桥接。
- **切片规则**：每个阶段先迁读模型，再迁写模型，最后再迁资源 ownership；每个切片必须通过 `zig build abi-check`、`zig build test`、`zig build` 和最小启动冒烟。

### 阶段完成标准

- **STR/Input owner 完成**：STR/Input 的 collection、parse、handle、ESC/control 决策均由 Zig 返回 plan；C 只保留 buffer 分配、指针持有和平台副作用，或已明确迁入下一阶段资源 ownership。
- **Line/History owner 完成**：scroll、resize、swap、history ring 的 pointer transaction 均由 Zig 返回可验证 plan；C 只执行指针交换、内存分配和清屏/dirty effect。
- **TermState owner 完成**：`term` 标量写回集中到 apply helpers，并由 Zig state update/effect plan 驱动；`st.c` 调用点不再分散维护同一组状态规则。
- **Platform shim 完成**：X11、PTY、clipboard、IO 的调用顺序由明确 effect plan 驱动；C 只保留系统调用和平台桥接实现。

### Platform shim 入口约束

- Platform shim 只能在 STR/Input、Line/History 和 TermState 的状态 ownership 稳定后开始实现。
- 第一批只允许把平台调用顺序表达为 effect plan，不允许迁移 X11 display、PTY fd、clipboard selection 或 IO fd 的资源 ownership。
- 任一切片若需要改变 `xsettitle`、`ttywrite`、`xwrite`、`xclipcopy`、`tswapscreen` 的真实调用时序，必须先补对应行为测试或启动冒烟场景。

## 当前模块

- `term_model.zig` 提供 `Point`、`Size`、`Rune` 和 glyph mode 判断。
- `st_color_core.zig` 通过 `ColorParams`、`ColorParse` 承载 SGR truecolor/indexed color 参数解析纯逻辑。
- `st_attr.zig` 通过 `SgrParams`、`AttrUpdate` 承载 SGR 属性更新规划，是 `tsetattr(...)` 的 Zig 迁移主体。
- `st_base64.zig` 通过 `Base64Input`、`Base64Decoder` 承载 OSC 等路径复用的 base64 解码入口。
- `st_csi.zig` 通过 `CsiParser`、`CsiArgParser` 和 `CsiExecPlan` 承载 CSI 原始字节解析、private marker 分类和 `csihandle` 顶层 command plan。
- `st_line_core.zig` 通过 `Line`、`Lines`、`TabStops`、`VisualLine`、`ExternalPipe`、`Viewport` 承载 line length、tab、dirty range、dump/external pipe plan 和 attr scan 纯逻辑。
- `st_state.zig` 通过 `ScrollBounds`、`ResizeRequest`、`ResizeTabs`、`ResetRequest`、`ResetExec`、`TabReset`、`ResizeClear` 承载 scroll region、resize、reset、tab 和 clear rect 规划；CSI set-scroll 的 cursor home coupling 由 `ZigStatePlan.cursor_home` 返回给 C executor，`treset()` 的双屏 reset ordering 由 `ZigResetExecPlan` 返回给 C executor。
- `st_edit.zig` 通过 `TextSpan`、`LineRegion`、`KeyboardScroll` 承载行内搬移、区域滚动、历史环形指针和键盘滚动规划；keyboard scroll 的 selection delta 和 full dirty effect 由 `ZigKScrollPlan` 返回给 C executor，`tscrollup` / `tscrolldown` 的 history swap 行、line swap loop 范围和 selection scroll delta 由 `ZigScrollPlan` 返回给 C executor。
- `st_cursor.zig` 通过 `TermCursor`、`ZigTermCursorSnapshot`、`ZigTermCursorPlan`、`DrawCursor` 和 `DrawExecPlan` 承载移动 clamp、origin-mode y 调整、换行、reverse-index、保存/恢复动作、draw frame/region 执行规划和 IME spot 更新判断。
- `st_erase.zig` 通过 `ClearRect` 承载清理矩形归一化。
- `st_mode.zig` 通过 `ModeParam`、`Utf8Selector`、`CharsetSelector`、`AltScreen` 承载 mode、UTF-8、charset、alternate screen swap、mouse mode、origin 和 simple bit/xsetmode action 分类；`1049/47/1047/1048` 的 cursor/clear/swap action 顺序、mouse mode 的 pointer/clear/set action、origin/simple bit action、WRAP/INSERT/ECHO/CRLF mask/bits、UTF-8 selector 和 charset selector 已由 Zig plan 承载，C executor 只执行 `tcursor`、`tclearregion`、`tswapscreen`、`xsetpointermotion`、`xsetmode`、`tmoveato` 和最终标量写回。
- `st_misc.zig` 通过 `TtyWrite` 承载 tty write chunk 辅助规划；printer、stty、tty pending 和 DEC test 这类一行比较已回退到 C 调用点。
- `st_strhandle.zig` 通过 `StringSequence`、`StringAction` 承载字符串序列启动、OSC/DCS action 分类、参数存在性和 OSC 52 运行判断。
- `st_strparse.zig` 通过 `StringParser` 承载 OSC/DCS 参数边界扫描。
- `st_putc_decode.zig` 通过 `RuneInput`、`ControlWriter` 承载 rune 解码和控制字符显示规划。
- `st_control_esc.zig` 通过 `EscSequence`、`ControlSequence` 承载 ESC/control 字节到纯 plan 的决策逻辑。
- `st_setchar.zig` 通过 `GlyphLine`、`PutcPrepare`、`StringCollector`、`InputControlPlan`、`InputEscPlan`、`InputEscFlowPlan` 和 `InputScalarStateUpdate` 承载字符写入、STR 收集、input 主线计划和 ESC/control 标量写回计划，并调用 `st_control_esc.zig` 的 ESC/control 决策逻辑。
- `st_utf8.zig` 通过 `Utf8Input`、`Utf8Rune` 承载 UTF-8 编解码。
- `st_selection.zig` 通过 `SelectionModel` 承载 selection start、extend、normalize、scroll、selected 和 getsel 输出范围写模型，并持有 selection adapter implementation 与 `export fn st_sel*` / `st_selected` / `st_getselexecplan`。
- `st_search.zig` 通过 `SearchModel` 承载 search 写模型入口，并保留输入编辑、插入缓冲区移动/扩容计划、基于 tagged union 的光标编辑、输入状态动作和 match append 动作、输入激活判断、match slice 集合判断、跳转、提交/取消、hit、line match、search history、`tlinehist` 历史行映射、可见行历史环形索引和 external pipe 历史行映射纯逻辑。
- `st_line.zig` 作为 line/external pipe 相关 C ABI adapter；history/search adapter implementation、`export fn st_search*` 和 C 标量到 `SearchModel` 的转换已下沉到 `st_search.zig`，selection adapter implementation 与 `export fn st_sel*` 已下沉到 `st_selection.zig`，`searchinputactive` 与 `searchbaractive` 已回退到 C executor。

## 当前状态

- 已迁移 Zig 模块的核心逻辑已按领域 `struct` 或内部值类型组织；`export fn` 目前仍主要保留为 C ABI adapter，但长期目标是持续删减。
- `st_line.zig`、`st_attr.zig`、`st_setchar.zig` 等 C 入口较多的文件仍允许保留 adapter helper，但新领域逻辑应继续下沉到内部类型方法，并避免形成新的长期 shim API。
- `st_zig.h` 与 Zig `export fn st_*` 符号集合已核对一致；当前仍是唯一公开 ABI，但定位已经调整为过渡兼容层。
- `ST_ZIG_*` 只暴露当前 C shim 实际分支需要的常量；Zig 内部状态如未被 C 使用，不进入 `st_zig.h`。
- Search 和 Selection 主流程已完成首轮迁移定版；近期工作以 ABI 瘦身和 effect 执行收口为主，已把一批 search/mode/strhandle 小 helper 回退到 C shim，并把 search 的资源释放、scan match reset、refresh-search 分支和 jump/redraw effect 集中到 C 侧 helper。本阶段重点不再是继续细碎删 helper，而是开始把状态所有权从 C 迁到 Zig。
- Resize 已收敛为 `ZigResizeExecPlan` 驱动的 C shim 顺序；Draw 已收敛为 `ZigDrawExecPlan` 驱动的 frame/region 副作用调用链，并开始作为 `TermState Owner` 大步切片使用 `ZigTermFrameSnapshot` 收口 search/screen/cursor/viewport 标量；cursor move、origin-mode y 调整、newline、reverse-index 和 save/load 已合并为 `ZigTermCursorSnapshot -> st_termcursorplan`。dirty draw consumption 由 `ZigDrawExecPlan.region_clear_dirty` 显式表达 state update，draw 完成后的 old-cursor state 写回由 `ZigDrawExecPlan.new_ocx/new_ocy` 返回，旧 `st_tmoveto`、`st_tcursororiginy`、`st_tnewline`、`st_treverseindex`、`st_tcursorplan`、`st_drawregionplan`、`st_drawframeplan` ABI 和头文件中的旧 `ZigDrawFramePlan` typedef 已删除。
- Reset ordering 已收敛为 `ZigResetExecPlan`：C 侧仍执行 `tmoveto`、`tcursor`、`tclearregion` 和 `tswapscreen` 副作用，但双屏 reset loop 的 action 顺序由 Zig state plan 明确返回。
- TermState 标量写回开始集中化：scroll region 的 `term.top` / `term.bot` 写回已收口到 `termapplyscrollregion()`，reset 的 cursor、scroll region、mode、charset 和 translation table 写回已收口到 `termapplyresetstate()`；后续同类 `term.*` 标量写回优先进入集中 apply helper。
- CSI 已完成大块聚合：`csihandle` 只调用 `st_csiexecplan` 获取 cursor/edit/erase/mode/state/attr/misc/light 顶层动作；旧 `st_plan*` 小 ABI、旧私有 planner 和 `st_light.zig` 重复模块已删除。
- Light/Tab 状态写回已收口：CSI tab clear 的 current/all tab 写回由 `ZigLightPlan.tab_clear_current/tab_clear_all` 驱动，C executor 只执行 `term.tabs` 数组写入或 `memset`。
- Mode/State 标量写回已完成收口：`tsetmode` simple bit writes 由 `ZigModePlan.mode_mask/mode_bits` 驱动，`tdefutf8` / `tdeftran` 改用 `st_tdefutf8plan` / `st_tdeftranplan`，media print mode、`toggleprinter()` 与 `ttynew(out)` 初始打印位由 `ZigMiscPlan.mode_mask/mode_bits` 驱动；C 仍保留真实平台 mode 副作用和最终标量写回。
- Mode actions 已完成前三条低风险切片：alternate screen / cursor save-load 路径不再依赖 C fallthrough 表达顺序，mouse mode 路径不再由 C 重复维护 pointer/clear/set 顺序，origin/visibility/simple bit action 也不再让 C 持有 `set/!set` 规则；`ZigModePlan` 返回 action fields，C 继续执行真实副作用和 `allowaltscreen` gate。unknown diagnostics 仍保留在 C。
- Input 已完成首批聚合：`tcontrolcode`、`eschandle` 和 `tputc` ESC flow 改用 `st_inputcontrolplan`、`st_inputescplan`、`st_inputescflowplan`；ESC flow 完成后的 `term.esc` 写回由 `ZigInputEscFlowPlan.finish_esc` 返回；STR collection 的 grow retry 和 reset buffer size 由 `st_tcollectstrapply()` / `st_strresetplan()` 返回，初始 buffer size 通过 `ST_ZIG_STR_BUF_SIZ` 同步，`st_strparse()` 返回参数 start/end 和 NUL 分隔写入元数据，`st_strhandleparplan()` / `st_strhandleplan()` 返回主参数解析规则和 payload/color 参数索引，C 通过 `strapplyplan()` 集中执行 title/clipboard/color 副作用，仍保留 `xrealloc` 和 `strescseq.buf` ownership；旧 ESC/control 碎片 ABI 已删除。
- Search 扫描已完成聚合：`searchscanline` 改用 `st_searchscanlineiter`，scan line 的 `x/nmatches/cap/y/scr` loop state 与 append/grow/stop 决策集中到 Zig；扫描结束后的 `nmatches/current` 收口也已改成 `st_searchscanupdate`；旧 `st_searchlineplan`、`st_searchlinematch`、`st_searchscanlineend`、`st_searchappendmatch` 小 ABI 已删除。
- Selection 输出已完成首批聚合：`getsel` 改用 snapshot 形态的 `st_getselexecplan`，`selected` 改用 snapshot 形态的 `st_selected`，旧 `st_getsellineplan`、`st_getselbufsize`、`st_getsellastx`、`st_getselnewline` 小 ABI 已删除；selection adapter implementation 与 export 已从 `st_line.zig` 下沉到 `st_selection.zig`。
- Selection result 消费已完成收口：`selstart` / `selextend` / `selscroll` 不再在调用点展开 state/dirty/clear effect，统一交给 C 侧 result executor 执行状态写回和必要副作用。
- ExternalPipe 已合并行长度、输出范围和 wrap newline 计划为 `st_externalpipeplan`，并按 deletion test 保留在 `st_line.zig`，因为它直接复用 `VisualLine` 与 line wrap 语义；C 保留历史行访问、UTF-8 编码和 pipe 写入副作用。
- `st_line.zig` 剩余 exports 已完成 deletion test：line length、tab、attr scan、dump、dirty range 和 external pipe 都仍承载 line 领域规则；当前不再继续机械拆分 line adapter。
- 已删除一批 deletion test 通过的 pass-through/obsolete ABI：`st_tdectest`、`st_ttywritecount`、`st_tprinterwrite`、`st_sttyfits`、`st_ttyreadpending`、`st_tscrollselplan`、`st_csiprivbool`、`st_tmoveato_y`、`st_tlineinregion`、`st_tdefutf8`、`st_tdeftran`、`st_ttywritechunk`、`st_drawframeplan`，以及头文件中不再被 C 消费的 `ZigDrawFramePlan` typedef。
- 低风险 shim-thinning 批次已关闭：Search、Selection、Draw、Resize、CSI、Input、Mode、Scroll/Edit、ExternalPipe 和 ABI/Test cleanup 都已到当前收益边界。后续如果继续推进，必须作为明确的 state ownership project，而不是继续机械合并 helper 或扫描浅 export。
- 主线 ownership 复查已关闭：Search buffer、term dirty、selection、term cursor/viewport、input mainline 和 ABI/Test sweep 当前都没有安全的小代码切片。后续只能在选定单一 owner 边界后重开，不再重复做宽泛扫描。

## 第一批迁移入口

- 第一批状态所有权迁移入口选 `search`。
- 原因：`search` 状态相对独立，已有大量纯逻辑在 Zig，近期又已删除多组小 ABI，最适合从“plan 驱动”升级到“Zig 持有状态 + effect plan”。
- 第一阶段已让 Zig 接管 `search` 的读模型：C 组装 `SearchSnapshot`，Zig 返回更大粒度的 `SearchStateUpdate` / `SearchEffectPlan`。
- 第二阶段已开始通过 `SearchModel` 收口 `search` 写模型 interface：`prompt/input/cursor/state/scan/set` 的 adapter implementation 与 `export fn st_search*` 已统一下沉到 `st_search.zig`；C 侧 `searchsnapshot()` / `searchapplyupdate()` 的标量字段映射也已集中到 `SearchScalarState` seam，并开始被 `searchnext/searchprev/searchjump/searchscan/searchmatch` 等调用点消费。`input` mutation transaction、`query` alloc/apply phase 和 `SearchScanIterator` scan line transaction 都已拆出独立 seam。当前结论是：`query`、`input` 与 `matches` ownership 都暂不迁到 Zig，因为 decode、指针替换、`xrealloc/memmove/memcpy`、scan/jump/redraw、match 数组写入等关键 effect 仍主要发生在 C shim，迁移 ownership 的新增协议成本高于当前收益。
- `search` 稳定后，再复制同一策略到 `sel`，最后再推进到 `term` 主状态。
- `sel` 当前已进入统一快照阶段：`SelectionModel` 已收口 start/extend/normalize/scroll/selected/getsel 状态决策，`st_selstartupdate`、`st_selextendupdate`、`st_selscrollupdate` 已替代旧 plan 入口；C 侧的 `selectionsnapshot()` / `selectionapplystate()` 已集中承载 Selection 状态读写映射，调用点不再重复展开 `sel` 字段；当前不迁 `sel` ownership，因为 `selsnap()` 仍依赖 C 侧 `TLINE(...)` / delimiter 读取，`getsel()` 仍由 C 执行 malloc、UTF-8 编码和 clipboard 输出。
- `selsnap()` 的 word loop 已从 `ZigSelSnapWordLoopSnapshot` 单步接口迁到 `SnapWordIterator` 两阶段接口：`st_selsnapworditerrequest` 负责返回下一读点，C 读取 glyph/line/wrap 事实后再经 `st_selsnapworditerresolve` 让 Zig 返回 accept/stop。旧 `st_selsnapwordplan`、`st_selsnapwordloopstep` ABI 已删除。

### 第一版结构

- `SearchSnapshot`
- 字段：`query_len`、`inputmode`、`inputlen`、`inputcursor`、`inputcap`、`nmatches`、`match_cap`、`current`、`active`
- 作用：让 Zig 在一次调用里拿到 search 当前元信息，不再靠多个零碎 `st_search*` helper 反复回读 C 状态
- 约束：第一版只放可直接复制的标量；`query`、`input`、`matches` 本体先继续由 C 持有并以切片/指针参数单独传入

- `SearchStateUpdate`
- 字段：`active`、`current`、`inputmode`、`inputlen`、`inputcursor`、`inputcap`、`nmatches`、`match_cap`
- 作用：承载 Zig 计算后的新状态，C 只做最终写回，不再分散逐字段修补
- 约束：第一版不直接携带堆内存所有权；涉及 `query`、`input`、`matches` 的 buffer 变更通过 effect 描述

- `SearchScalarState`
- 字段：`query_len`、`active`、`current`、`inputmode`、`inputlen`、`inputcursor`、`inputcap`、`nmatches`、`match_cap`
- 作用：作为 C 侧的 search 标量状态 seam，统一承载 `searchsnapshot()` 的读映射和 `searchapplyupdate()` 的写映射，并开始作为 `searchnext/searchprev/searchjump/searchscan/searchmatch/searchbaractive` 等调用点的共享读写视图，避免同一组字段在多个 helper 中重复展开
- 约束：只覆盖标量状态，不持有 `query`、`input`、`matches` 指针或其资源所有权；平台副作用与 buffer 生命周期仍留在 C

- `SearchEffectPlan`
- 字段：`alloc_input`、`realloc_input`、`alloc_query`、`realloc_matches`、`clear_query`、`clear_matches`、`refresh_search`、`redraw`、`jump`
- 作用：把 realloc/free/redraw/searchscan/searchjump 这类副作用从状态更新里分离出来，C shim 只按计划执行
- 约束：effect 只描述“做什么”，不直接持有平台资源；真正的 `xmalloc`、`xrealloc`、`free`、`redraw` 仍在 C 执行

- `SearchQuerySeams`
- 组成：`searchallocquerybuffer()` alloc phase、`searchapplydecodedquery()` apply phase、`searchapplyqueryreplace()` replace transaction
- 作用：把 `searchset()` 拆成 alloc/decode/apply 三段事务，让 query 的分配尺度、decoded `qlen`、clear/replace/scan/jump 时序各自可验证
- 约束：当前只拆事务，不迁 `search.query` ownership；`Rune *query` 指针和 free 生命周期仍留在 C

- `SearchInputSeams`
- 组成：`ZigSearchInputState`、`st_searchinputstate()`、`st_searchdeleteplan()`、`searchapplyinputmutation()`、`searchapplyinputinsert()`、`searchapplyinputdelete()`、`searchapplyinputclear()`
- 作用：把 input scalar state、grow/insert/delete/clear 事务和 `searchset()` 触发条件收口到可验证的 transaction seam；delete 事务已由 Zig 返回删除后的 input scalar state，C 通过统一 mutation executor 执行 `xrealloc`、`memmove`、`memcpy`、清空和写回
- 约束：当前只拆事务，不迁 `search.input` ownership；`char *input` 指针和 `xmalloc/xrealloc/free` 生命周期仍留在 C

- `SearchScanIteratorSeam`
- 组成：`ZigSearchScanLineState`、`ZigSearchScanLineStep`、`st_searchscanlineiter()`
- 作用：把 scan line 的 `x/nmatches/cap/y/scr` loop state、append/grow/stop 决策和 `SearchMatch` 值对象生成收口到 Zig iterator seam
- 约束：当前只拆 scan transaction，不迁 `search.matches` ownership；`SearchMatch *matches` 指针、`xrealloc/free` 和数组写入仍留在 C

### 第一批接入点

- `searchprompt()`：已切到 `SearchSnapshot -> PromptUpdate + alloc_input effect`，C 只执行输入 buffer 分配和 redraw effect。
- `searchinput()`：已切到 `SearchSnapshot + input bytes -> SearchStateUpdate + realloc_input effect`，C 只执行 realloc/memmove/memcpy 后触发 `searchset()`。
- `searchset()`：已切到 `SearchSnapshot + decoded query -> SearchStateUpdate + alloc_query/jump/redraw effect`，C 只执行 UTF-8 decode、query 指针替换、scan/jump/redraw。
- `searchapplycursor()` / `searchapplystate()`：已收口到 `SearchCursorResult` / `SearchStateResult`，C 侧先构造 `SearchSnapshot`，再消费 update/effect；cursor delete 事务已由 `ZigSearchCursorResult` 返回 delete range 与 post-delete `ZigSearchInputState`，clear/commit/cancel 也由 `ZigSearchStateResult` 返回 post-action `ZigSearchInputState`，C 只执行 `memmove()`、free/redraw 等副作用。

## 完成定义

- 迁移目标调整为：先把 C 压缩成极薄 shim，再让 Zig 逐步接管状态所有权和主线决策。
- C 侧长期只保留平台桥接、系统调用、资源生命周期、最终副作用执行和必要的兼容 ABI。
- Zig 侧不仅承载纯计划和解析逻辑，还要逐步承载 `term` / `sel` / `search` 的权威状态模型。
- 后续新增行为如果只依赖值参数并返回计划结果，应直接进入 Zig 内部类型；如果当前仍需要访问 C 全局状态，应优先设计新的快照/更新结构，为后续搬迁所有权做准备，而不是新增长期 C 逻辑。
- 下一阶段工作已选择 `term` 的 Dirty + Cursor + Draw 作为明确 owner seam；继续一次只迁这个状态族，不把 line buffer ownership、history ownership 或平台 effect 混进同一批。

## 验证基线

- 结构化迁移完成后已运行 `zig fmt` 覆盖修改过的 Zig 文件。
- 当前基线验证命令为 `zig build abi-check`、`zig build test` 和 `zig build`。
- `zig build abi-check` 用于核对 Zig export 与 C 头文件符号集合，避免手写 `st_zig.h` 漏同步。
- 发布或提交前仍建议按迁移规则补跑 `timeout 5 ./zig-out/bin/st` 做最小启动冒烟验证。

## 迁移规则

- 新增领域逻辑优先放入内部模块，再从 adapter 调用。
- 如果逻辑仍需要访问 C 全局状态或执行副作用，先判断能否改成“快照输入 + 更新输出”；只有真正的平台桥接代码才允许长期留在 C shim。
- 优先减少 ABI 数量；C 未调用、只服务 Zig adapter 测试的 `export fn` 应删除，测试改为覆盖内部领域函数。
- 不新增小 helper 迁移碎片；后续更优先的产物是 state snapshot、state update、effect plan，而不是更多细粒度 `st_*` 导出。
- 迁移状态所有权时，先迁读模型，再迁写模型，最后再迁资源所有权；不要一步把状态和平台副作用混在同一批里重做。
- 每批迁移保持单一主题，运行 `zig fmt`、`zig build test`、`zig build` 和 `timeout 5 ./zig-out/bin/st` 后再提交。
- 不为缺失配置或异常状态添加静默默认值；错误信息必须保留上下文。
