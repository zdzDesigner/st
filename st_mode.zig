//! st_mode.zig 负责 DEC/private mode、UTF-8 mode 与 charset mode 参数分类。
//! [输入]: private marker、单个 mode 参数、UTF-8 selector 或 charset selector。
//! [输出]: `ZigModePlan`、更新后的 terminal mode，或 charset 编号。
//! [副作用边界]: 不调用 `xsetmode(...)`、`xsetpointermotion(...)`、`tswapscreen(...)`；C 侧保留所有模式副作用。
//! [定位]: 让 `tsetmode(...)`、`tdefutf8(...)`、`tdeftran(...)` 的参数识别逻辑可测试，同时避免 Zig 复制 C/X11 mode 副作用。

const std = @import("std");

pub const ZigModePlan = extern struct {
    kind: c_int,
    cursor_store_action: c_int,
    swap_screen: c_int,
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

const term_mode_utf8 = 1 << 6;
const charset_graphic0 = 0;
const charset_usa = 3;
const charset_unknown = -1;

const ModeParam = struct {
    private: bool,
    arg: c_int,

    fn plan(self: ModeParam, set: bool, alt: bool) ZigModePlan {
        if (self.private) {
            return .{ .kind = switch (self.arg) {
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
            }, .cursor_store_action = cursorAction(self.arg, set), .swap_screen = swapScreen(self.arg, set, alt) };
        }

        return .{ .kind = switch (self.arg) {
            0 => mode_ignore,
            2 => mode_kbdlock,
            4 => mode_insert,
            12 => mode_echo,
            20 => mode_crlf,
            else => mode_regular_unknown,
        }, .cursor_store_action = -1, .swap_screen = 0 };
    }
};

const Utf8Selector = struct {
    ascii: c_char,

    fn apply(self: Utf8Selector, mode: c_int) c_int {
        return switch (self.ascii) {
            'G' => mode | term_mode_utf8,
            '@' => mode & ~@as(c_int, term_mode_utf8),
            else => mode,
        };
    }
};

const CharsetSelector = struct {
    ascii: c_char,

    fn value(self: CharsetSelector) c_int {
        return switch (self.ascii) {
            '0' => charset_graphic0,
            'B' => charset_usa,
            else => charset_unknown,
        };
    }
};

const AltScreen = struct {
    fn shouldSwap(set: bool, alt: bool) bool {
        return set != alt;
    }
};

fn cursorAction(arg: c_int, set: bool) c_int {
    return switch (arg) {
        1049, 1048 => if (set) 0 else 1,
        else => -1,
    };
}

fn swapScreen(arg: c_int, set: bool, alt: bool) c_int {
    return switch (arg) {
        1049, 47, 1047 => if (AltScreen.shouldSwap(set, alt)) 1 else 0,
        else => 0,
    };
}

export fn st_modeplan(priv: c_int, arg: c_int, set: c_int, alt: c_int) ZigModePlan {
    return (ModeParam{ .private = priv != 0, .arg = arg }).plan(set != 0, alt != 0);
}

export fn st_tdefutf8(mode: c_int, ascii: c_char) c_int {
    return (Utf8Selector{ .ascii = ascii }).apply(mode);
}

export fn st_tdeftran(ascii: c_char) c_int {
    return (CharsetSelector{ .ascii = ascii }).value();
}

test "private 1049 maps to alt1049" {
    const plan = st_modeplan(1, 1049, 1, 0);
    try std.testing.expectEqual(@as(c_int, mode_alt1049), plan.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.cursor_store_action);
    try std.testing.expectEqual(@as(c_int, 1), plan.swap_screen);
}

test "private 1005 stays ignored" {
    const plan = st_modeplan(1, 1005, 1, 0);
    try std.testing.expectEqual(@as(c_int, mode_ignore), plan.kind);
}

test "private unknown reports private unknown" {
    const plan = st_modeplan(1, 9999, 1, 0);
    try std.testing.expectEqual(@as(c_int, mode_private_unknown), plan.kind);
}

test "regular 2 maps to kbdlock" {
    const plan = st_modeplan(0, 2, 1, 0);
    try std.testing.expectEqual(@as(c_int, mode_kbdlock), plan.kind);
}

test "regular 12 maps to echo" {
    const plan = st_modeplan(0, 12, 1, 0);
    try std.testing.expectEqual(@as(c_int, mode_echo), plan.kind);
}

test "regular unknown reports regular unknown" {
    const plan = st_modeplan(0, 99, 1, 0);
    try std.testing.expectEqual(@as(c_int, mode_regular_unknown), plan.kind);
}

test "tdefutf8 enables and disables utf8 bit" {
    try std.testing.expectEqual(@as(c_int, term_mode_utf8), st_tdefutf8(0, 'G'));
    try std.testing.expectEqual(@as(c_int, 0), st_tdefutf8(term_mode_utf8, '@'));
}

test "tdefutf8 ignores unknown selector" {
    try std.testing.expectEqual(@as(c_int, 5), st_tdefutf8(5, 'x'));
}

test "tdeftran maps supported charsets" {
    try std.testing.expectEqual(@as(c_int, charset_graphic0), st_tdeftran('0'));
    try std.testing.expectEqual(@as(c_int, charset_usa), st_tdeftran('B'));
}

test "tdeftran reports unknown selector" {
    try std.testing.expectEqual(@as(c_int, charset_unknown), st_tdeftran('x'));
}
