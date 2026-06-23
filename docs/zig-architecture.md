# Zig 架构边界

## 目标

Zig 代码按领域职责组织，避免把 `st.c` 中的 `if` 分支直接搬成长期 ABI helper。C 侧继续作为 executor，Zig 侧承载可测试的纯领域决策。

## 边界

- C 负责全局状态、`TLINE(...)`、内存所有权、X11、PTY、clipboard、IO 和实际副作用执行。
- Zig 内部模块负责值类型模型、状态机、范围计算、编辑计划、匹配计划和可单元测试的纯逻辑。
- Zig 内部模块优先用领域 `struct` 管理状态，并把响应行为放在方法上；裸函数只保留为 adapter 兼容入口或无状态工具。
- `export fn` 所在文件负责 C ABI adapter：把 C 标量、extern struct 和指针切片转换成 Zig 内部类型。
- 内部模块不直接暴露给 C，不读取 `term`、`sel` 等 C 全局变量。

## 当前模块

- `term_model.zig` 提供 `Point`、`Size`、`Rune` 和 glyph mode 判断。
- `st_color_core.zig` 通过 `ColorParams`、`ColorParse` 承载 SGR truecolor/indexed color 参数解析纯逻辑。
- `st_attr.zig` 通过 `SgrParams`、`AttrUpdate` 承载 SGR 属性更新规划，是 `tsetattr(...)` 的 Zig 迁移主体。
- `st_base64.zig` 通过 `Base64Input`、`Base64Decoder` 承载 OSC 等路径复用的 base64 解码入口。
- `st_csi.zig` 通过 `CsiParser`、`CsiArgParser` 和 `CsiExecPlan` 承载 CSI 原始字节解析、private marker 分类和 `csihandle` 顶层 command plan。
- `st_line_core.zig` 通过 `Line`、`Lines`、`TabStops`、`VisualLine`、`ExternalPipe`、`Viewport` 承载 line length、tab、dirty range、dump/external pipe plan 和 attr scan 纯逻辑。
- `st_state.zig` 通过 `CsiCommand`、`ScrollBounds`、`ResizeRequest`、`ResizeTabs`、`ResetRequest`、`TabReset`、`ResizeClear` 承载 CSI 状态、scroll region、resize、reset、tab 和 clear rect 规划。
- `st_edit.zig` 通过 `EditCommand`、`TextSpan`、`LineRegion`、`KeyboardScroll` 承载 CSI edit、行内搬移、区域滚动、历史环形指针和键盘滚动规划。
- `st_cursor.zig` 通过 `CursorCommand`、`CursorMove`、`CursorLine`、`CursorOrigin`、`DrawCursor`、`CursorStore` 承载 CSI 光标、移动 clamp、换行、draw cursor、IME spot 更新判断和保存/恢复规划。
- `st_erase.zig` 通过 `EraseCommand`、`ClearRect` 承载 ED/EL 清理计划和清理矩形归一化。
- `st_mode.zig` 通过 `ModeParam`、`Utf8Selector`、`CharsetSelector`、`AltScreen` 承载 mode、UTF-8、charset 和 alternate screen 参数分类。
- `st_light.zig` 通过 `LightCommand` 承载轻量 CSI 动作分类。
- `st_misc.zig` 通过 `MiscCommand`、`TtyWrite` 承载杂项 CSI plan 和 tty write chunk 规划。
- `st_strhandle.zig` 通过 `StringSequence`、`StringAction`、`StringArgs` 承载字符串序列启动和 OSC/DCS action 分类。
- `st_strparse.zig` 通过 `StringParser` 承载 OSC/DCS 参数边界扫描。
- `st_putc_decode.zig` 通过 `RuneInput`、`ControlWriter` 承载 rune 解码和控制字符显示规划。
- `st_control_esc.zig` 通过 `EscSequence`、`ControlSequence` 承载 ESC/control 字节到执行计划的纯决策逻辑。
- `st_setchar.zig` 通过 `GlyphLine`、`PutcPrepare`、`StringCollector`、`EscFlow` 承载字符写入、STR 收集和 ESC flow adapter，并调用 `st_control_esc.zig` 的 ESC/control 决策逻辑。
- `st_utf8.zig` 通过 `Utf8Input`、`Utf8Rune` 承载 UTF-8 编解码。
- `st_selection.zig` 承载 selection snap、normalize、extend、scroll、getsel 输出范围等纯逻辑。
- `st_search.zig` 承载 search 输入编辑、插入缓冲区移动/扩容计划、基于 tagged union 的光标编辑、输入状态动作和 match append 动作、输入激活判断、match slice 集合判断、跳转、提交/取消、hit、line match、search history、可见行历史环形索引和 external pipe 历史行映射纯逻辑。
- `st_line.zig` 作为 line、selection、search/history 相关 C ABI adapter，并集中处理 C 标量到 Zig enum/bool/value object 的薄转换。

## 当前状态

- 已迁移 Zig 模块的核心逻辑已按领域 `struct` 或内部值类型组织；`export fn` 主要保留为 C ABI adapter。
- `st_line.zig`、`st_attr.zig`、`st_setchar.zig` 等 C 入口较多的文件仍允许保留 adapter helper，但新领域逻辑应继续下沉到内部类型方法。
- `st_zig.h` 与 Zig `export fn st_*` 符号集合已核对一致；C 侧只依赖公开的 `ST_ZIG_*` 常量和 extern struct 布局。
- `ST_ZIG_*` 只暴露 C executor 实际分支需要的常量；Zig 内部状态如未被 C 使用，不进入 `st_zig.h`。
- Search 和 Selection 主流程已完成迁移定版；后续只做局部优化、无用 ABI 删除或更大粒度 command plan 聚合。
- Resize 已收敛为 `ZigResizeExecPlan` 驱动的 C executor 顺序；Draw 已收敛为 frame/region plan 驱动的副作用调用链。
- CSI 已完成首批大块聚合：`csihandle` 只调用 `st_csiexecplan` 获取 cursor/edit/erase/mode/state/attr/misc/light 顶层动作；旧 `st_plan*` 小 ABI 已删除。
- ExternalPipe 已合并行长度、输出范围和 wrap newline 计划为 `st_externalpipeplan`；C 保留历史行访问、UTF-8 编码和 pipe 写入副作用。

## 完成定义

- 迁移目标不是完全消除 C，而是把可测试的纯决策逻辑从 `st.c` 收敛到 Zig 领域模块。
- C 侧保留 executor 职责：全局状态写回、X11/PTY/clipboard/IO、内存所有权、`TLINE(...)` 访问和实际副作用调用。
- Zig 侧已覆盖 UTF-8、CSI/OSC/DCS 解析、SGR 属性和颜色、光标、编辑、清屏、模式、滚动、selection、search、字符写入和 line 级计划。
- 后续新增行为如果只依赖值参数并返回计划结果，应优先进入 Zig 内部类型；如果需要访问 C 全局状态或执行副作用，应留在 C executor。

## 验证基线

- 结构化迁移完成后已运行 `zig fmt` 覆盖修改过的 Zig 文件。
- 当前基线验证命令为 `zig build abi-check`、`zig build test` 和 `zig build`。
- `zig build abi-check` 用于核对 Zig export 与 C 头文件符号集合，避免手写 `st_zig.h` 漏同步。
- 发布或提交前仍建议按迁移规则补跑 `timeout 5 ./zig-out/bin/st` 做最小启动冒烟验证。

## 迁移规则

- 新增领域逻辑优先放入内部模块，再从 adapter 调用。
- 如果逻辑需要访问 C 全局状态或执行副作用，保留在 C 或 executor 层。
- 优先减少 ABI 数量；C 未调用、只服务 Zig adapter 测试的 `export fn` 应删除，测试改为覆盖内部领域函数。
- 不新增小 helper 迁移碎片；CSI/ESC、Line/ExternalPipe 等后续迁移应优先产出更大粒度 exec/frame/command plan。
- 每批迁移保持单一主题，运行 `zig fmt`、`zig build test`、`zig build` 和 `timeout 5 ./zig-out/bin/st` 后再提交。
- 不为缺失配置或异常状态添加静默默认值；错误信息必须保留上下文。
