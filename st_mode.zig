//! st_mode.zig 负责 DEC/private mode 与普通 mode 参数分类。
//! [输入]: private marker 和单个 mode 参数。
//! [输出]: `ZigModePlan`，告诉 C 侧这是哪一种 terminal/window mode 操作或 unknown。
//! [副作用边界]: 不调用 `xsetmode(...)`、`xsetpointermotion(...)`、`tswapscreen(...)`；C 侧保留所有模式副作用。
//! [定位]: 让 `tsetmode(...)` 的参数识别逻辑可测试，同时避免 Zig 复制 C/X11 mode flag。

const std = @import("std");

pub const ZigModePlan = extern struct {
    kind: c_int,
};

pub const mode_ignore = 0;
pub const mode_private_unknown = 1;
pub const mode_regular_unknown = 2;
pub const mode_appcursor = 3;
pub const mode_reverse = 4;
pub const mode_origin = 5;
pub const mode_wrap = 6;
pub const mode_cursor_visibility = 7;
pub const mode_mouse_x10 = 8;
pub const mode_mouse_btn = 9;
pub const mode_mouse_motion = 10;
pub const mode_mouse_many = 11;
pub const mode_focus = 12;
pub const mode_mouse_sgr = 13;
pub const mode_8bit = 14;
pub const mode_alt1049 = 15;
pub const mode_alt47 = 16;
pub const mode_cursor1048 = 17;
pub const mode_bracketed_paste = 18;
pub const mode_kbdlock = 19;
pub const mode_insert = 20;
pub const mode_echo = 21;
pub const mode_crlf = 22;

export fn st_planmode(priv: c_int, arg: c_int) ZigModePlan {
    if (priv != 0) {
        return .{ .kind = switch (arg) {
            1 => mode_appcursor,
            5 => mode_reverse,
            6 => mode_origin,
            7 => mode_wrap,
            0, 2, 3, 4, 8, 12, 18, 19, 42, 1001, 1005, 1015 => mode_ignore,
            25 => mode_cursor_visibility,
            9 => mode_mouse_x10,
            1000 => mode_mouse_btn,
            1002 => mode_mouse_motion,
            1003 => mode_mouse_many,
            1004 => mode_focus,
            1006 => mode_mouse_sgr,
            1034 => mode_8bit,
            1049 => mode_alt1049,
            47, 1047 => mode_alt47,
            1048 => mode_cursor1048,
            2004 => mode_bracketed_paste,
            else => mode_private_unknown,
        } };
    }

    return .{ .kind = switch (arg) {
        0 => mode_ignore,
        2 => mode_kbdlock,
        4 => mode_insert,
        12 => mode_echo,
        20 => mode_crlf,
        else => mode_regular_unknown,
    } };
}

test "private 1049 maps to alt1049" {
    const plan = st_planmode(1, 1049);
    try std.testing.expectEqual(@as(c_int, mode_alt1049), plan.kind);
}

test "private 1005 stays ignored" {
    const plan = st_planmode(1, 1005);
    try std.testing.expectEqual(@as(c_int, mode_ignore), plan.kind);
}

test "private unknown reports private unknown" {
    const plan = st_planmode(1, 9999);
    try std.testing.expectEqual(@as(c_int, mode_private_unknown), plan.kind);
}

test "regular 2 maps to kbdlock" {
    const plan = st_planmode(0, 2);
    try std.testing.expectEqual(@as(c_int, mode_kbdlock), plan.kind);
}

test "regular 12 maps to echo" {
    const plan = st_planmode(0, 12);
    try std.testing.expectEqual(@as(c_int, mode_echo), plan.kind);
}

test "regular unknown reports regular unknown" {
    const plan = st_planmode(0, 99);
    try std.testing.expectEqual(@as(c_int, mode_regular_unknown), plan.kind);
}
