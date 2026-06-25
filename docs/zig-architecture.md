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

## 当前模块

- `term_model.zig` 提供 `Point`、`Size`、`Rune` 和 glyph mode 判断。
- `st_color_core.zig` 通过 `ColorParams`、`ColorParse` 承载 SGR truecolor/indexed color 参数解析纯逻辑。
- `st_attr.zig` 通过 `SgrParams`、`AttrUpdate` 承载 SGR 属性更新规划，是 `tsetattr(...)` 的 Zig 迁移主体。
- `st_base64.zig` 通过 `Base64Input`、`Base64Decoder` 承载 OSC 等路径复用的 base64 解码入口。
- `st_csi.zig` 通过 `CsiParser`、`CsiArgParser` 和 `CsiExecPlan` 承载 CSI 原始字节解析、private marker 分类和 `csihandle` 顶层 command plan。
- `st_line_core.zig` 通过 `Line`、`Lines`、`TabStops`、`VisualLine`、`ExternalPipe`、`Viewport` 承载 line length、tab、dirty range、dump/external pipe plan 和 attr scan 纯逻辑。
- `st_state.zig` 通过 `ScrollBounds`、`ResizeRequest`、`ResizeTabs`、`ResetRequest`、`TabReset`、`ResizeClear` 承载 scroll region、resize、reset、tab 和 clear rect 规划。
- `st_edit.zig` 通过 `TextSpan`、`LineRegion`、`KeyboardScroll` 承载行内搬移、区域滚动、历史环形指针和键盘滚动规划。
- `st_cursor.zig` 通过 `CursorMove`、`CursorLine`、`CursorOrigin`、`DrawCursor`、`CursorStore` 承载移动 clamp、换行、draw cursor、IME spot 更新判断和保存/恢复规划。
- `st_erase.zig` 通过 `ClearRect` 承载清理矩形归一化。
- `st_mode.zig` 通过 `ModeParam`、`Utf8Selector`、`CharsetSelector`、`AltScreen` 承载 mode、UTF-8、charset、alternate screen swap 和 cursor save/load 参数分类；alternate screen 位切换由 C executor 本地完成。
- `st_misc.zig` 通过 `TtyWrite` 承载 tty write chunk、printer、stty 和 DEC test 辅助规划。
- `st_strhandle.zig` 通过 `StringSequence`、`StringAction` 承载字符串序列启动、OSC/DCS action 分类、参数存在性和 OSC 52 运行判断。
- `st_strparse.zig` 通过 `StringParser` 承载 OSC/DCS 参数边界扫描。
- `st_putc_decode.zig` 通过 `RuneInput`、`ControlWriter` 承载 rune 解码和控制字符显示规划。
- `st_control_esc.zig` 通过 `EscSequence`、`ControlSequence` 承载 ESC/control 字节到纯 plan 的决策逻辑。
- `st_setchar.zig` 通过 `GlyphLine`、`PutcPrepare`、`StringCollector`、`InputControlPlan`、`InputEscPlan`、`InputEscFlowPlan` 承载字符写入、STR 收集和 input 主线计划，并调用 `st_control_esc.zig` 的 ESC/control 决策逻辑。
- `st_utf8.zig` 通过 `Utf8Input`、`Utf8Rune` 承载 UTF-8 编解码。
- `st_selection.zig` 承载 selection snap、normalize、extend、scroll、getsel 输出范围等纯逻辑。
- `st_search.zig` 承载 search 输入编辑、插入缓冲区移动/扩容计划、基于 tagged union 的光标编辑、输入状态动作和 match append 动作、输入激活判断、match slice 集合判断、跳转、提交/取消、hit、line match、search history、可见行历史环形索引和 external pipe 历史行映射纯逻辑。
- `st_line.zig` 作为 line、selection、search/history 相关 C ABI adapter，并集中处理 C 标量到 Zig enum/bool/value object 的薄转换；`searchinputactive` 与 `searchbaractive` 已回退到 C executor。

## 当前状态

- 已迁移 Zig 模块的核心逻辑已按领域 `struct` 或内部值类型组织；`export fn` 目前仍主要保留为 C ABI adapter，但长期目标是持续删减。
- `st_line.zig`、`st_attr.zig`、`st_setchar.zig` 等 C 入口较多的文件仍允许保留 adapter helper，但新领域逻辑应继续下沉到内部类型方法，并避免形成新的长期 shim API。
- `st_zig.h` 与 Zig `export fn st_*` 符号集合已核对一致；当前仍是唯一公开 ABI，但定位已经调整为过渡兼容层。
- `ST_ZIG_*` 只暴露当前 C shim 实际分支需要的常量；Zig 内部状态如未被 C 使用，不进入 `st_zig.h`。
- Search 和 Selection 主流程已完成首轮迁移定版；近期工作以 ABI 瘦身为主，已把一批 search/mode/strhandle 小 helper 回退到 C shim。本阶段重点不再是继续细碎删 helper，而是开始把状态所有权从 C 迁到 Zig。
- Resize 已收敛为 `ZigResizeExecPlan` 驱动的 C shim 顺序；Draw 已收敛为 frame/region plan 驱动的副作用调用链。
- CSI 已完成大块聚合：`csihandle` 只调用 `st_csiexecplan` 获取 cursor/edit/erase/mode/state/attr/misc/light 顶层动作；旧 `st_plan*` 小 ABI、旧私有 planner 和 `st_light.zig` 重复模块已删除。
- Input 已完成首批聚合：`tcontrolcode`、`eschandle` 和 `tputc` ESC flow 改用 `st_inputcontrolplan`、`st_inputescplan`、`st_inputescflowplan`；旧 ESC/control 碎片 ABI 已删除。
- Search 扫描已完成聚合：`searchscanline` 改用 `st_searchlineplan`，旧 `st_searchlinematch`、`st_searchscanlineend`、`st_searchappendmatch` 小 ABI 已删除。
- Selection 输出已完成首批聚合：`getsel` 改用 `st_getselexecplan`，旧 `st_getsellineplan`、`st_getselbufsize`、`st_getsellastx`、`st_getselnewline` 小 ABI 已删除。
- ExternalPipe 已合并行长度、输出范围和 wrap newline 计划为 `st_externalpipeplan`；C 保留历史行访问、UTF-8 编码和 pipe 写入副作用。

## 第一批迁移入口

- 第一批状态所有权迁移入口选 `search`。
- 原因：`search` 状态相对独立，已有大量纯逻辑在 Zig，近期又已删除多组小 ABI，最适合从“plan 驱动”升级到“Zig 持有状态 + effect plan”。
- 第一阶段先让 Zig 接管 `search` 的读模型：C 组装 `SearchSnapshot`，Zig 返回更大粒度的 `SearchStateUpdate` / `SearchEffectPlan`。
- 第二阶段再让 Zig 接管 `search` 的写模型：C 不再分散写 `search.active`、`search.current`、`search.inputlen`、`search.inputcursor`、`search.query` 元信息，只执行 realloc/free/redraw 等副作用。
- `search` 稳定后，再复制同一策略到 `sel`，最后再推进到 `term` 主状态。

### 第一版结构

- `SearchSnapshot`
- 字段：`query_len`、`inputmode`、`inputlen`、`inputcursor`、`inputcap`、`nmatches`、`match_cap`、`current`、`active`
- 作用：让 Zig 在一次调用里拿到 search 当前元信息，不再靠多个零碎 `st_search*` helper 反复回读 C 状态
- 约束：第一版只放可直接复制的标量；`query`、`input`、`matches` 本体先继续由 C 持有并以切片/指针参数单独传入

- `SearchStateUpdate`
- 字段：`active`、`current`、`inputmode`、`inputlen`、`inputcursor`、`inputcap`、`nmatches`、`match_cap`
- 作用：承载 Zig 计算后的新状态，C 只做最终写回，不再分散逐字段修补
- 约束：第一版不直接携带堆内存所有权；涉及 `query`、`input`、`matches` 的 buffer 变更通过 effect 描述

- `SearchEffectPlan`
- 字段：`alloc_input`、`realloc_input`、`alloc_query`、`realloc_matches`、`clear_query`、`clear_matches`、`refresh_search`、`redraw`、`jump`
- 作用：把 realloc/free/redraw/searchscan/searchjump 这类副作用从状态更新里分离出来，C shim 只按计划执行
- 约束：effect 只描述“做什么”，不直接持有平台资源；真正的 `xmalloc`、`xrealloc`、`free`、`redraw` 仍在 C 执行

### 第一批接入点

- `searchprompt()`：最适合先切到 `SearchSnapshot -> PromptUpdate + alloc_input effect`
- `searchinput()`：适合切到 `SearchSnapshot + input bytes -> SearchStateUpdate + realloc_input effect`
- `searchset()`：适合切到 `SearchSnapshot + decoded query -> SearchStateUpdate + alloc_query/realloc_matches/jump/redraw effect`
- `searchapplyedit()` / `searchapplystateedit()`：作为第二批，等 `searchprompt/searchinput/searchset` 稳定后再收口

## 完成定义

- 迁移目标调整为：先把 C 压缩成极薄 shim，再让 Zig 逐步接管状态所有权和主线决策。
- C 侧长期只保留平台桥接、系统调用、资源生命周期、最终副作用执行和必要的兼容 ABI。
- Zig 侧不仅承载纯计划和解析逻辑，还要逐步承载 `term` / `sel` / `search` 的权威状态模型。
- 后续新增行为如果只依赖值参数并返回计划结果，应直接进入 Zig 内部类型；如果当前仍需要访问 C 全局状态，应优先设计新的快照/更新结构，为后续搬迁所有权做准备，而不是新增长期 C 逻辑。

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
