//! st_term_update.zig 提供 terminal state update 的共享 Zig ABI 类型。
//! [输入]: 各领域 planner 产出的终端标量写回。
//! [输出]: `ZigTermStateUpdate`。
//! [副作用边界]: 不读取或写入 C 的 `term` 全局状态；C 侧 executor 执行真实写回。
//! [定位]: 避免 Zig 模块为了复用 update 类型而 import 带 export fn 的领域模块。

pub const ZigTermStateUpdate = extern struct {
    set_cursor: c_int,
    cursor_attr_mode: c_ushort,
    cursor_fg: u32,
    cursor_bg: u32,
    cursor_x: c_int,
    cursor_y: c_int,
    cursor_state: c_int,
    mode_mask: c_int,
    mode_bits: c_int,
    cursor_state_mask: c_int,
    cursor_state_bits: c_int,
    set_charset: c_int,
    charset: c_int,
    set_trantbl: c_int,
    trantbl_slot: c_int,
    trantbl_charset: c_int,
    set_all_trantbl: c_int,
    all_trantbl_charset: c_int,
    set_scroll_region: c_int,
    top: c_int,
    bot: c_int,
    set_dimensions: c_int,
    col: c_int,
    maxcol: c_int,
    row: c_int,
    clamp_cursor: c_int,
};
