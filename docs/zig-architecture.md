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
- `st_line_core.zig` 通过 `Line`、`Lines`、`TabStops`、`VisualLine`、`Viewport` 承载 line length、tab、dirty range、dump/external pipe plan 和 attr scan 纯逻辑。
- `st_state.zig` 通过 `CsiCommand`、`ScrollBounds`、`ResizeRequest`、`ResizeTabs`、`ResetRequest`、`TabReset`、`ResizeClear` 承载 CSI 状态、scroll region、resize、reset、tab 和 clear rect 规划。
- `st_edit.zig` 通过 `EditCommand`、`TextSpan`、`LineRegion`、`KeyboardScroll` 承载 CSI edit、行内搬移、区域滚动和键盘滚动规划。
- `st_cursor.zig` 通过 `CursorCommand`、`CursorMove`、`CursorLine`、`CursorOrigin`、`DrawCursor`、`CursorStore` 承载 CSI 光标、移动 clamp、换行、draw cursor 和保存/恢复规划。
- `st_selection.zig` 承载 selection snap、normalize、extend、scroll、getsel 输出范围等纯逻辑。
- `st_search.zig` 承载 search 输入编辑、跳转、提交/取消、hit 和 line match 纯逻辑。
- `st_line.zig` 作为 line、selection、search 相关 C ABI adapter。

## 迁移规则

- 新增领域逻辑优先放入内部模块，再从 adapter 调用。
- 如果逻辑需要访问 C 全局状态或执行副作用，保留在 C 或 executor 层。
- 每批迁移保持单一主题，运行 `zig fmt`、`zig build test`、`zig build` 和 `timeout 5 ./zig-out/bin/st` 后再提交。
- 不为缺失配置或异常状态添加静默默认值；错误信息必须保留上下文。
