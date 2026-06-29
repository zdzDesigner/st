//! st_mode.zig 负责 DEC/private mode、UTF-8 mode 与 charset mode 参数分类。
//! [输入]: private marker、单个 mode 参数、UTF-8 selector 或 charset selector。
//! [输出]: `ZigModePlan`、mode action 顺序、更新后的 terminal mode，或 charset 编号。
//! [副作用边界]: 不调用 `xsetmode(...)`、`xsetpointermotion(...)`、`tswapscreen(...)`；C 侧保留所有模式副作用。
//! [定位]: 让 `tsetmode(...)`、`tdefutf8(...)`、`tdeftran(...)` 的参数识别和低风险 mode action 顺序可测试，同时避免 Zig 复制 C/X11 mode 副作用。

const std = @import("std");

pub const ZigModePlan = extern struct {
    kind: c_int,
    cursor_before: c_int,
    clear_before_swap: c_int,
    swap_screen: c_int,
    cursor_after: c_int,
    pointer_motion: c_int,
    clear_mouse_mode: c_int,
    mouse_mode: c_int,
    cursor_state_action: c_int,
    cursor_state_set: c_int,
    move_origin_home: c_int,
    term_mode_action: c_int,
    term_mode_set: c_int,
    xsetmode_action: c_int,
    xsetmode_set: c_int,
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

pub const mouse_none = 0;
pub const mouse_x10 = 1;
pub const mouse_button = 2;
pub const mouse_motion = 3;
pub const mouse_many = 4;
pub const mouse_sgr = 5;

pub const cursor_state_none = 0;
pub const cursor_state_origin = 1;

pub const term_mode_none = 0;
pub const term_mode_wrap = 1;
pub const term_mode_insert = 2;
pub const term_mode_echo = 3;
pub const term_mode_crlf = 4;

pub const xsetmode_none = 0;
pub const xsetmode_hide = 1;
pub const xsetmode_kbdlock = 2;

const term_mode_utf8 = 1 << 6;
const charset_graphic0 = 0;
const charset_usa = 3;
const charset_unknown = -1;

const ModeParam = struct {
    private: bool,
    arg: c_int,

    fn plan(self: ModeParam, set: bool, alt: bool) ZigModePlan {
        if (self.private) {
            return modePlan(switch (self.arg) {
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
            }, self.arg, set, alt);
        }

        return modePlan(switch (self.arg) {
            0 => mode_ignore,
            2 => mode_kbdlock,
            4 => mode_insert,
            12 => mode_echo,
            20 => mode_crlf,
            else => mode_regular_unknown,
        }, self.arg, set, alt);
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

fn modePlan(kind: c_int, arg: c_int, set: bool, alt: bool) ZigModePlan {
    const cursor_action = cursorAction(arg, set);
    return .{
        .kind = kind,
        .cursor_before = if (arg == 1049) cursor_action else -1,
        .clear_before_swap = if ((arg == 1049 or arg == 47 or arg == 1047) and alt) 1 else 0,
        .swap_screen = swapScreen(arg, set, alt),
        .cursor_after = if (arg == 1049 or arg == 1048) cursor_action else -1,
        .pointer_motion = pointerMotion(arg, set),
        .clear_mouse_mode = clearMouseMode(arg),
        .mouse_mode = mouseMode(arg),
        .cursor_state_action = cursorStateAction(arg),
        .cursor_state_set = if (set) 1 else 0,
        .move_origin_home = if (arg == 6) 1 else 0,
        .term_mode_action = termModeAction(arg),
        .term_mode_set = if (arg == 12) (if (!set) 1 else 0) else (if (set) 1 else 0),
        .xsetmode_action = xsetmodeAction(arg),
        .xsetmode_set = if (arg == 25) (if (!set) 1 else 0) else (if (set) 1 else 0),
    };
}

fn cursorStateAction(arg: c_int) c_int {
    return if (arg == 6) cursor_state_origin else cursor_state_none;
}

fn termModeAction(arg: c_int) c_int {
    return switch (arg) {
        7 => term_mode_wrap,
        4 => term_mode_insert,
        12 => term_mode_echo,
        20 => term_mode_crlf,
        else => term_mode_none,
    };
}

fn xsetmodeAction(arg: c_int) c_int {
    return switch (arg) {
        25 => xsetmode_hide,
        2 => xsetmode_kbdlock,
        else => xsetmode_none,
    };
}

fn pointerMotion(arg: c_int, set: bool) c_int {
    return switch (arg) {
        9, 1000, 1002 => 0,
        1003 => if (set) 1 else 0,
        else => -1,
    };
}

fn clearMouseMode(arg: c_int) c_int {
    return switch (arg) {
        9, 1000, 1002, 1003 => 1,
        else => 0,
    };
}

fn mouseMode(arg: c_int) c_int {
    return switch (arg) {
        9 => mouse_x10,
        1000 => mouse_button,
        1002 => mouse_motion,
        1003 => mouse_many,
        1006 => mouse_sgr,
        else => mouse_none,
    };
}

export fn st_modeplan(priv: c_int, arg: c_int, set: c_int, alt: c_int) ZigModePlan {
    return (ModeParam{ .private = priv != 0, .arg = arg }).plan(set != 0, alt != 0);
}

test "mode domain plans alternate screen set" {
    const plan = modePlan(mode_alt1049, 1049, true, false);
    try std.testing.expectEqual(@as(c_int, mode_alt1049), plan.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.cursor_before);
    try std.testing.expectEqual(@as(c_int, 0), plan.cursor_after);
    try std.testing.expectEqual(@as(c_int, 1), plan.swap_screen);
}

test "mode domain plans 1049 reset order" {
    const plan = modePlan(mode_alt1049, 1049, false, true);
    try std.testing.expectEqual(@as(c_int, mode_alt1049), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.cursor_before);
    try std.testing.expectEqual(@as(c_int, 1), plan.clear_before_swap);
    try std.testing.expectEqual(@as(c_int, 1), plan.swap_screen);
    try std.testing.expectEqual(@as(c_int, 1), plan.cursor_after);
}

test "mode domain keeps 47 separate from cursor" {
    const plan = modePlan(mode_alt47, 47, false, true);
    try std.testing.expectEqual(@as(c_int, mode_alt47), plan.kind);
    try std.testing.expectEqual(@as(c_int, -1), plan.cursor_before);
    try std.testing.expectEqual(@as(c_int, 1), plan.clear_before_swap);
    try std.testing.expectEqual(@as(c_int, 1), plan.swap_screen);
    try std.testing.expectEqual(@as(c_int, -1), plan.cursor_after);
}

test "mode domain plans 1048 cursor action" {
    const plan = modePlan(mode_cursor1048, 1048, true, false);
    try std.testing.expectEqual(@as(c_int, mode_cursor1048), plan.kind);
    try std.testing.expectEqual(@as(c_int, -1), plan.cursor_before);
    try std.testing.expectEqual(@as(c_int, 0), plan.clear_before_swap);
    try std.testing.expectEqual(@as(c_int, 0), plan.swap_screen);
    try std.testing.expectEqual(@as(c_int, 0), plan.cursor_after);
}

test "mode helper maps mouse actions" {
    try std.testing.expectEqual(@as(c_int, 0), pointerMotion(9, true));
    try std.testing.expectEqual(@as(c_int, 1), pointerMotion(1003, true));
    try std.testing.expectEqual(@as(c_int, 0), pointerMotion(1003, false));
    try std.testing.expectEqual(@as(c_int, -1), pointerMotion(1006, true));
    try std.testing.expectEqual(@as(c_int, 1), clearMouseMode(1000));
    try std.testing.expectEqual(@as(c_int, 0), clearMouseMode(1006));
    try std.testing.expectEqual(@as(c_int, mouse_x10), mouseMode(9));
    try std.testing.expectEqual(@as(c_int, mouse_sgr), mouseMode(1006));
    try std.testing.expectEqual(@as(c_int, mouse_none), mouseMode(1005));
}

test "mode domain plans mouse actions" {
    const x10 = modePlan(mode_mouse_x10, 9, true, false);
    const button = modePlan(mode_mouse_btn, 1000, true, false);
    const motion = modePlan(mode_mouse_motion, 1002, true, false);
    try std.testing.expectEqual(@as(c_int, mode_mouse_x10), x10.kind);
    try std.testing.expectEqual(@as(c_int, 0), x10.pointer_motion);
    try std.testing.expectEqual(@as(c_int, 1), x10.clear_mouse_mode);
    try std.testing.expectEqual(@as(c_int, mouse_x10), x10.mouse_mode);
    try std.testing.expectEqual(@as(c_int, mouse_button), button.mouse_mode);
    try std.testing.expectEqual(@as(c_int, mouse_motion), motion.mouse_mode);
}

test "mode domain plans mouse many pointer motion" {
    const enabled = modePlan(mode_mouse_many, 1003, true, false);
    const disabled = modePlan(mode_mouse_many, 1003, false, false);
    try std.testing.expectEqual(@as(c_int, mode_mouse_many), enabled.kind);
    try std.testing.expectEqual(@as(c_int, 1), enabled.pointer_motion);
    try std.testing.expectEqual(@as(c_int, 0), disabled.pointer_motion);
    try std.testing.expectEqual(@as(c_int, 1), enabled.clear_mouse_mode);
    try std.testing.expectEqual(@as(c_int, mouse_many), enabled.mouse_mode);
}

test "mode domain plans mouse sgr" {
    const plan = modePlan(mode_mouse_sgr, 1006, true, false);
    try std.testing.expectEqual(@as(c_int, mode_mouse_sgr), plan.kind);
    try std.testing.expectEqual(@as(c_int, -1), plan.pointer_motion);
    try std.testing.expectEqual(@as(c_int, 0), plan.clear_mouse_mode);
    try std.testing.expectEqual(@as(c_int, mouse_sgr), plan.mouse_mode);
}

test "mode helper maps origin and simple actions" {
    try std.testing.expectEqual(@as(c_int, cursor_state_origin), cursorStateAction(6));
    try std.testing.expectEqual(@as(c_int, cursor_state_none), cursorStateAction(7));
    try std.testing.expectEqual(@as(c_int, term_mode_wrap), termModeAction(7));
    try std.testing.expectEqual(@as(c_int, term_mode_insert), termModeAction(4));
    try std.testing.expectEqual(@as(c_int, term_mode_echo), termModeAction(12));
    try std.testing.expectEqual(@as(c_int, term_mode_crlf), termModeAction(20));
    try std.testing.expectEqual(@as(c_int, term_mode_none), termModeAction(5));
    try std.testing.expectEqual(@as(c_int, xsetmode_hide), xsetmodeAction(25));
    try std.testing.expectEqual(@as(c_int, xsetmode_kbdlock), xsetmodeAction(2));
    try std.testing.expectEqual(@as(c_int, xsetmode_none), xsetmodeAction(7));
}

test "mode domain plans origin action" {
    const plan = modePlan(mode_origin, 6, true, false);
    try std.testing.expectEqual(@as(c_int, cursor_state_origin), plan.cursor_state_action);
    try std.testing.expectEqual(@as(c_int, 1), plan.cursor_state_set);
    try std.testing.expectEqual(@as(c_int, 1), plan.move_origin_home);
}

test "mode domain plans visibility and simple bit writes" {
    const visibility = modePlan(mode_cursor_visibility, 25, true, false);
    const wrap = modePlan(mode_wrap, 7, true, false);
    const insert = modePlan(mode_insert, 4, true, false);
    const echo = modePlan(mode_echo, 12, true, false);
    const crlf = modePlan(mode_crlf, 20, true, false);
    const kbdlock = modePlan(mode_kbdlock, 2, true, false);
    try std.testing.expectEqual(@as(c_int, xsetmode_hide), visibility.xsetmode_action);
    try std.testing.expectEqual(@as(c_int, 0), visibility.xsetmode_set);
    try std.testing.expectEqual(@as(c_int, term_mode_wrap), wrap.term_mode_action);
    try std.testing.expectEqual(@as(c_int, 1), wrap.term_mode_set);
    try std.testing.expectEqual(@as(c_int, term_mode_insert), insert.term_mode_action);
    try std.testing.expectEqual(@as(c_int, term_mode_echo), echo.term_mode_action);
    try std.testing.expectEqual(@as(c_int, 0), echo.term_mode_set);
    try std.testing.expectEqual(@as(c_int, term_mode_crlf), crlf.term_mode_action);
    try std.testing.expectEqual(@as(c_int, xsetmode_kbdlock), kbdlock.xsetmode_action);
}

test "mode adapter smoke plan export" {
    const alt = st_modeplan(1, 1049, 0, 1);
    const mouse = st_modeplan(1, 1003, 1, 0);
    const origin = st_modeplan(1, 6, 1, 0);
    try std.testing.expectEqual(@as(c_int, mode_alt1049), alt.kind);
    try std.testing.expectEqual(@as(c_int, mouse_many), mouse.mouse_mode);
    try std.testing.expectEqual(@as(c_int, cursor_state_origin), origin.cursor_state_action);
}

test "mode adapter smoke keeps unknown classification" {
    const plan = st_modeplan(1, 9999, 1, 0);
    try std.testing.expectEqual(@as(c_int, mode_private_unknown), plan.kind);
    try std.testing.expectEqual(@as(c_int, mode_ignore), st_modeplan(1, 1005, 1, 0).kind);
}

test "mode adapter smoke keeps regular unknown classification" {
    const plan = st_modeplan(0, 99, 1, 0);
    try std.testing.expectEqual(@as(c_int, mode_regular_unknown), plan.kind);
}

test "utf8 selector enables and disables utf8 bit" {
    try std.testing.expectEqual(@as(c_int, term_mode_utf8), (Utf8Selector{ .ascii = 'G' }).apply(0));
    try std.testing.expectEqual(@as(c_int, 0), (Utf8Selector{ .ascii = '@' }).apply(term_mode_utf8));
}

test "utf8 selector ignores unknown selector" {
    try std.testing.expectEqual(@as(c_int, 5), (Utf8Selector{ .ascii = 'x' }).apply(5));
}

test "charset selector maps supported charsets" {
    try std.testing.expectEqual(@as(c_int, charset_graphic0), (CharsetSelector{ .ascii = '0' }).value());
    try std.testing.expectEqual(@as(c_int, charset_usa), (CharsetSelector{ .ascii = 'B' }).value());
}

test "charset selector reports unknown selector" {
    try std.testing.expectEqual(@as(c_int, charset_unknown), (CharsetSelector{ .ascii = 'x' }).value());
}
