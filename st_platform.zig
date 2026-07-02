//! st_platform.zig 负责 Zig/C 平台 effect ABI 与 effect kind 编号。
//! [输入]: STR、mode、draw 等 planner 产出的平台副作用请求。
//! [输出]: `ZigPlatformEffectList`、platform effect kind 和 platform mode kind。
//! [副作用边界]: 不执行 X11、PTY、clipboard 或 draw 副作用；C 侧 executor 保留真实资源 ownership。
//! [定位]: 所有 Zig planner 与 `st_zig.h` 之间的平台 effect 单一类型来源。

const std = @import("std");

pub const ZigPlatformEffect = extern struct {
    kind: c_int,
    arg: c_int,
    index_arg: c_int,
};

pub const ZigPlatformEffectList = extern struct {
    count: c_int,
    effects: [8]ZigPlatformEffect,
};

pub const effect_none = 0;
pub const effect_set_title = 1;
pub const effect_set_icon_title = 2;
pub const effect_decode_clipboard = 3;
pub const effect_set_selection = 4;
pub const effect_copy_clipboard = 5;
pub const effect_set_color = 6;
pub const effect_reset_color = 7;
pub const effect_redraw = 8;
pub const effect_unknown_str = 9;
pub const effect_xsetmode = 10;
pub const effect_pointer_motion = 11;
pub const effect_cursor = 12;
pub const effect_clear_screen = 13;
pub const effect_swap_screen = 14;
pub const effect_move_origin = 15;
pub const effect_search_scan = 16;
pub const effect_draw_region = 17;
pub const effect_draw_cursor = 18;
pub const effect_finish_draw = 19;
pub const effect_ime_spot = 20;
pub const effect_mode_unknown_private = 21;
pub const effect_mode_unknown_regular = 22;
pub const effect_region_clear_dirty = 23;
pub const effect_region_draw_line = 24;
pub const effect_region_advance = 25;

pub const mode_appcursor = 1;
pub const mode_reverse = 2;
pub const mode_hide = 3;
pub const mode_mouse = 4;
pub const mode_mousex10 = 5;
pub const mode_mousebtn = 6;
pub const mode_mousemotion = 7;
pub const mode_mousemany = 8;
pub const mode_focus = 9;
pub const mode_mousesgr = 10;
pub const mode_8bit = 11;
pub const mode_brcktpaste = 12;
pub const mode_kbdlock = 13;

pub fn emptyEffects() ZigPlatformEffectList {
    return .{ .count = 0, .effects = std.mem.zeroes([8]ZigPlatformEffect) };
}

pub fn addEffect(list: *ZigPlatformEffectList, kind: c_int, arg: c_int, index_arg: c_int) void {
    if (@as(usize, @intCast(list.count)) >= list.effects.len) return;
    list.effects[@intCast(list.count)] = .{ .kind = kind, .arg = arg, .index_arg = index_arg };
    list.count += 1;
}
