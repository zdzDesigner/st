//! st_mode.zig 负责 DEC/private mode、UTF-8 mode 与 charset mode 参数分类。
//! [输入]: private marker、单个 mode 参数、UTF-8 selector 或 charset selector。
//! [输出]: `ZigModePlan`、mode action 顺序、更新后的 terminal mode，或 charset 编号。
//! [副作用边界]: 不调用 `xsetmode(...)`、`xsetpointermotion(...)`、`tswapscreen(...)`；C 侧保留所有模式副作用。
//! [定位]: 让 `tsetmode(...)`、`tdefutf8(...)`、`tdeftran(...)` 的参数识别和低风险 mode action 顺序可测试，同时避免 Zig 复制 C/X11 mode 副作用。

const std = @import("std");
const platform = @import("st_platform.zig");
const term_update = @import("st_term_update.zig");

const ZigPlatformEffectList = platform.ZigPlatformEffectList;
const ZigTermStateUpdate = term_update.ZigTermStateUpdate;

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
    cursor_state_mask: c_int,
    cursor_state_bits: c_int,
    move_origin_home: c_int,
    term_mode_action: c_int,
    term_mode_set: c_int,
    mode_mask: c_int,
    mode_bits: c_int,
    xsetmode_action: c_int,
    xsetmode_set: c_int,
    platform: ZigPlatformEffectList,
    term_update: ZigTermStateUpdate,
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

const term_mode_wrap_bit = 1 << 0;
const term_mode_insert_bit = 1 << 1;
const term_mode_crlf_bit = 1 << 3;
const term_mode_echo_bit = 1 << 4;
const cursor_origin_bit = 1 << 1;

pub const xsetmode_none = 0;
pub const xsetmode_hide = 1;
pub const xsetmode_kbdlock = 2;

const term_mode_utf8 = 1 << 6;
const charset_graphic0 = 0;
const charset_usa = 3;
const charset_unknown = -1;
const platform_effect_xsetmode = platform.effect_xsetmode;
const platform_effect_pointer_motion = platform.effect_pointer_motion;
const platform_effect_cursor = platform.effect_cursor;
const platform_effect_clear_screen = platform.effect_clear_screen;
const platform_effect_swap_screen = platform.effect_swap_screen;
const platform_effect_move_origin = platform.effect_move_origin;
const platform_effect_mode_unknown_private = platform.effect_mode_unknown_private;
const platform_effect_mode_unknown_regular = platform.effect_mode_unknown_regular;
const platform_mode_appcursor = platform.mode_appcursor;
const platform_mode_reverse = platform.mode_reverse;
const platform_mode_hide = platform.mode_hide;
const platform_mode_mouse = platform.mode_mouse;
const platform_mode_mousex10 = platform.mode_mousex10;
const platform_mode_mousebtn = platform.mode_mousebtn;
const platform_mode_mousemotion = platform.mode_mousemotion;
const platform_mode_mousemany = platform.mode_mousemany;
const platform_mode_focus = platform.mode_focus;
const platform_mode_mousesgr = platform.mode_mousesgr;
const platform_mode_8bit = platform.mode_8bit;
const platform_mode_brcktpaste = platform.mode_brcktpaste;
const platform_mode_kbdlock = platform.mode_kbdlock;

const ModeParam = struct {
    private: bool,
    arg: c_int,

    fn plan(self: ModeParam, set: bool, alt: bool, allow_alt: bool) ZigModePlan {
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
            }, self.arg, set, alt, allow_alt);
        }

        return modePlan(switch (self.arg) {
            0 => mode_ignore,
            2 => mode_kbdlock,
            4 => mode_insert,
            12 => mode_echo,
            20 => mode_crlf,
            else => mode_regular_unknown,
        }, self.arg, set, alt, allow_alt);
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

fn modePlan(kind: c_int, arg: c_int, set: bool, alt: bool, allow_alt: bool) ZigModePlan {
    const cursor_action = cursorAction(arg, set);
    const term_mode_set = if (arg == 12) !set else set;
    const term_mask = termModeMask(arg);
    var plan = ZigModePlan{
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
        .cursor_state_mask = cursorStateMask(arg),
        .cursor_state_bits = if (set) cursorStateMask(arg) else 0,
        .move_origin_home = if (arg == 6) 1 else 0,
        .term_mode_action = termModeAction(arg),
        .term_mode_set = if (term_mode_set) 1 else 0,
        .mode_mask = term_mask,
        .mode_bits = if (term_mode_set) term_mask else 0,
        .xsetmode_action = xsetmodeAction(arg),
        .xsetmode_set = if (arg == 25) (if (!set) 1 else 0) else (if (set) 1 else 0),
        .platform = emptyPlatformEffects(),
        .term_update = std.mem.zeroes(ZigTermStateUpdate),
    };
    plan.term_update.cursor_state_mask = plan.cursor_state_mask;
    plan.term_update.cursor_state_bits = plan.cursor_state_bits;
    plan.term_update.mode_mask = plan.mode_mask;
    plan.term_update.mode_bits = plan.mode_bits;
    fillPlatformEffects(&plan, arg, set, alt, allow_alt);
    return plan;
}

fn emptyPlatformEffects() ZigPlatformEffectList {
    return platform.emptyEffects();
}

fn addPlatformEffect(list: *ZigPlatformEffectList, kind: c_int, arg: c_int, index_arg: c_int) void {
    platform.addEffect(list, kind, arg, index_arg);
}

fn addXsetmode(list: *ZigPlatformEffectList, set: bool, mode: c_int) void {
    addPlatformEffect(list, platform_effect_xsetmode, if (set) 1 else 0, mode);
}

fn fillPlatformEffects(plan: *ZigModePlan, arg: c_int, set: bool, alt: bool, allow_alt: bool) void {
    switch (plan.kind) {
        mode_private_unknown => addPlatformEffect(&plan.platform, platform_effect_mode_unknown_private, arg, 0),
        mode_regular_unknown => addPlatformEffect(&plan.platform, platform_effect_mode_unknown_regular, arg, 0),
        mode_appcursor => addXsetmode(&plan.platform, set, platform_mode_appcursor),
        mode_reverse => addXsetmode(&plan.platform, set, platform_mode_reverse),
        mode_cursor_visibility => addXsetmode(&plan.platform, plan.xsetmode_set != 0, platform_mode_hide),
        mode_mouse_x10, mode_mouse_btn, mode_mouse_motion, mode_mouse_many => {
            if (plan.pointer_motion >= 0) addPlatformEffect(&plan.platform, platform_effect_pointer_motion, plan.pointer_motion, 0);
            if (plan.clear_mouse_mode != 0) addXsetmode(&plan.platform, false, platform_mode_mouse);
            switch (plan.mouse_mode) {
                mouse_x10 => addXsetmode(&plan.platform, set, platform_mode_mousex10),
                mouse_button => addXsetmode(&plan.platform, set, platform_mode_mousebtn),
                mouse_motion => addXsetmode(&plan.platform, set, platform_mode_mousemotion),
                mouse_many => addXsetmode(&plan.platform, set, platform_mode_mousemany),
                else => {},
            }
        },
        mode_focus => addXsetmode(&plan.platform, set, platform_mode_focus),
        mode_mouse_sgr => if (plan.mouse_mode == mouse_sgr) addXsetmode(&plan.platform, set, platform_mode_mousesgr),
        mode_8bit => addXsetmode(&plan.platform, set, platform_mode_8bit),
        mode_alt1049 => {
            if (!allow_alt) return;
            if (plan.cursor_before >= 0) addPlatformEffect(&plan.platform, platform_effect_cursor, plan.cursor_before, 0);
            if (plan.clear_before_swap != 0 and alt) addPlatformEffect(&plan.platform, platform_effect_clear_screen, 0, 0);
            if (plan.swap_screen != 0) addPlatformEffect(&plan.platform, platform_effect_swap_screen, 0, 0);
            if (plan.cursor_after >= 0) addPlatformEffect(&plan.platform, platform_effect_cursor, plan.cursor_after, 0);
        },
        mode_alt47 => {
            if (!allow_alt) return;
            if (plan.clear_before_swap != 0 and alt) addPlatformEffect(&plan.platform, platform_effect_clear_screen, 0, 0);
            if (plan.swap_screen != 0) addPlatformEffect(&plan.platform, platform_effect_swap_screen, 0, 0);
        },
        mode_cursor1048 => if (plan.cursor_after >= 0) addPlatformEffect(&plan.platform, platform_effect_cursor, plan.cursor_after, 0),
        mode_bracketed_paste => addXsetmode(&plan.platform, set, platform_mode_brcktpaste),
        mode_kbdlock => addXsetmode(&plan.platform, plan.xsetmode_set != 0, platform_mode_kbdlock),
        mode_origin => if (plan.move_origin_home != 0) addPlatformEffect(&plan.platform, platform_effect_move_origin, 0, 0),
        else => {},
    }
}

fn termModeMask(arg: c_int) c_int {
    return switch (arg) {
        7 => term_mode_wrap_bit,
        4 => term_mode_insert_bit,
        12 => term_mode_echo_bit,
        20 => term_mode_crlf_bit,
        else => 0,
    };
}

fn cursorStateAction(arg: c_int) c_int {
    return if (arg == 6) cursor_state_origin else cursor_state_none;
}

fn cursorStateMask(arg: c_int) c_int {
    return if (arg == 6) cursor_origin_bit else 0;
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

export fn st_modeplan(priv: c_int, arg: c_int, set: c_int, alt: c_int, allow_alt: c_int) ZigModePlan {
    return (ModeParam{ .private = priv != 0, .arg = arg }).plan(set != 0, alt != 0, allow_alt != 0);
}

export fn st_tdefutf8plan(ascii: c_char, mode: c_int) c_int {
    return (Utf8Selector{ .ascii = ascii }).apply(mode);
}

export fn st_tdeftranplan(ascii: c_char) c_int {
    return (CharsetSelector{ .ascii = ascii }).value();
}

test "mode domain plans alternate screen set" {
    const plan = modePlan(mode_alt1049, 1049, true, false, true);
    try std.testing.expectEqual(@as(c_int, mode_alt1049), plan.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.cursor_before);
    try std.testing.expectEqual(@as(c_int, 0), plan.cursor_after);
    try std.testing.expectEqual(@as(c_int, 1), plan.swap_screen);
}

test "mode domain plans 1049 reset order" {
    const plan = modePlan(mode_alt1049, 1049, false, true, true);
    try std.testing.expectEqual(@as(c_int, mode_alt1049), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.cursor_before);
    try std.testing.expectEqual(@as(c_int, 1), plan.clear_before_swap);
    try std.testing.expectEqual(@as(c_int, 1), plan.swap_screen);
    try std.testing.expectEqual(@as(c_int, 1), plan.cursor_after);
}

test "mode domain gates alt screen effects when disabled" {
    const plan = modePlan(mode_alt1049, 1049, false, true, false);
    try std.testing.expectEqual(@as(c_int, mode_alt1049), plan.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.platform.count);
}

test "mode domain returns unknown diagnostic effects" {
    const private_plan = st_modeplan(1, 9999, 1, 0, 1);
    const regular_plan = st_modeplan(0, 99, 1, 0, 1);

    try std.testing.expectEqual(@as(c_int, mode_private_unknown), private_plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), private_plan.platform.count);
    try std.testing.expectEqual(@as(c_int, platform_effect_mode_unknown_private), private_plan.platform.effects[0].kind);
    try std.testing.expectEqual(@as(c_int, 9999), private_plan.platform.effects[0].arg);
    try std.testing.expectEqual(@as(c_int, mode_regular_unknown), regular_plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), regular_plan.platform.count);
    try std.testing.expectEqual(@as(c_int, platform_effect_mode_unknown_regular), regular_plan.platform.effects[0].kind);
    try std.testing.expectEqual(@as(c_int, 99), regular_plan.platform.effects[0].arg);
}

test "mode domain keeps 47 separate from cursor" {
    const plan = modePlan(mode_alt47, 47, false, true, true);
    try std.testing.expectEqual(@as(c_int, mode_alt47), plan.kind);
    try std.testing.expectEqual(@as(c_int, -1), plan.cursor_before);
    try std.testing.expectEqual(@as(c_int, 1), plan.clear_before_swap);
    try std.testing.expectEqual(@as(c_int, 1), plan.swap_screen);
    try std.testing.expectEqual(@as(c_int, -1), plan.cursor_after);
}

test "mode domain plans 1048 cursor action" {
    const plan = modePlan(mode_cursor1048, 1048, true, false, true);
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
    const x10 = modePlan(mode_mouse_x10, 9, true, false, true);
    const button = modePlan(mode_mouse_btn, 1000, true, false, true);
    const motion = modePlan(mode_mouse_motion, 1002, true, false, true);
    try std.testing.expectEqual(@as(c_int, mode_mouse_x10), x10.kind);
    try std.testing.expectEqual(@as(c_int, 0), x10.pointer_motion);
    try std.testing.expectEqual(@as(c_int, 1), x10.clear_mouse_mode);
    try std.testing.expectEqual(@as(c_int, mouse_x10), x10.mouse_mode);
    try std.testing.expectEqual(@as(c_int, mouse_button), button.mouse_mode);
    try std.testing.expectEqual(@as(c_int, mouse_motion), motion.mouse_mode);
}

test "mode domain plans mouse many pointer motion" {
    const enabled = modePlan(mode_mouse_many, 1003, true, false, true);
    const disabled = modePlan(mode_mouse_many, 1003, false, false, true);
    try std.testing.expectEqual(@as(c_int, mode_mouse_many), enabled.kind);
    try std.testing.expectEqual(@as(c_int, 1), enabled.pointer_motion);
    try std.testing.expectEqual(@as(c_int, 0), disabled.pointer_motion);
    try std.testing.expectEqual(@as(c_int, 1), enabled.clear_mouse_mode);
    try std.testing.expectEqual(@as(c_int, mouse_many), enabled.mouse_mode);
    try std.testing.expectEqual(@as(c_int, 3), enabled.platform.count);
    try std.testing.expectEqual(@as(c_int, platform_effect_pointer_motion), enabled.platform.effects[0].kind);
    try std.testing.expectEqual(@as(c_int, platform_effect_xsetmode), enabled.platform.effects[1].kind);
    try std.testing.expectEqual(@as(c_int, platform_mode_mouse), enabled.platform.effects[1].index_arg);
    try std.testing.expectEqual(@as(c_int, platform_mode_mousemany), enabled.platform.effects[2].index_arg);
}

test "mode domain plans mouse sgr" {
    const plan = modePlan(mode_mouse_sgr, 1006, true, false, true);
    try std.testing.expectEqual(@as(c_int, mode_mouse_sgr), plan.kind);
    try std.testing.expectEqual(@as(c_int, -1), plan.pointer_motion);
    try std.testing.expectEqual(@as(c_int, 0), plan.clear_mouse_mode);
    try std.testing.expectEqual(@as(c_int, mouse_sgr), plan.mouse_mode);
}

test "mode helper maps origin and simple actions" {
    try std.testing.expectEqual(@as(c_int, cursor_state_origin), cursorStateAction(6));
    try std.testing.expectEqual(@as(c_int, cursor_state_none), cursorStateAction(7));
    try std.testing.expectEqual(@as(c_int, cursor_origin_bit), cursorStateMask(6));
    try std.testing.expectEqual(@as(c_int, 0), cursorStateMask(7));
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
    const plan = modePlan(mode_origin, 6, true, false, true);
    try std.testing.expectEqual(@as(c_int, cursor_state_origin), plan.cursor_state_action);
    try std.testing.expectEqual(@as(c_int, 1), plan.cursor_state_set);
    try std.testing.expectEqual(@as(c_int, cursor_origin_bit), plan.cursor_state_mask);
    try std.testing.expectEqual(@as(c_int, cursor_origin_bit), plan.cursor_state_bits);
    try std.testing.expectEqual(@as(c_int, 1), plan.move_origin_home);
}

test "mode domain plans visibility and simple bit writes" {
    const visibility = modePlan(mode_cursor_visibility, 25, true, false, true);
    const wrap = modePlan(mode_wrap, 7, true, false, true);
    const insert = modePlan(mode_insert, 4, true, false, true);
    const echo = modePlan(mode_echo, 12, true, false, true);
    const crlf = modePlan(mode_crlf, 20, true, false, true);
    const kbdlock = modePlan(mode_kbdlock, 2, true, false, true);
    try std.testing.expectEqual(@as(c_int, xsetmode_hide), visibility.xsetmode_action);
    try std.testing.expectEqual(@as(c_int, 0), visibility.xsetmode_set);
    try std.testing.expectEqual(@as(c_int, term_mode_wrap), wrap.term_mode_action);
    try std.testing.expectEqual(@as(c_int, 1), wrap.term_mode_set);
    try std.testing.expectEqual(@as(c_int, term_mode_wrap_bit), wrap.mode_mask);
    try std.testing.expectEqual(@as(c_int, term_mode_wrap_bit), wrap.mode_bits);
    try std.testing.expectEqual(@as(c_int, term_mode_insert), insert.term_mode_action);
    try std.testing.expectEqual(@as(c_int, term_mode_insert_bit), insert.mode_mask);
    try std.testing.expectEqual(@as(c_int, term_mode_insert_bit), insert.mode_bits);
    try std.testing.expectEqual(@as(c_int, term_mode_echo), echo.term_mode_action);
    try std.testing.expectEqual(@as(c_int, 0), echo.term_mode_set);
    try std.testing.expectEqual(@as(c_int, term_mode_echo_bit), echo.mode_mask);
    try std.testing.expectEqual(@as(c_int, 0), echo.mode_bits);
    try std.testing.expectEqual(@as(c_int, term_mode_crlf), crlf.term_mode_action);
    try std.testing.expectEqual(@as(c_int, term_mode_crlf_bit), crlf.mode_mask);
    try std.testing.expectEqual(@as(c_int, term_mode_crlf_bit), crlf.mode_bits);
    try std.testing.expectEqual(@as(c_int, xsetmode_kbdlock), kbdlock.xsetmode_action);
}

test "mode adapter smoke plan export" {
    const alt = st_modeplan(1, 1049, 0, 1, 1);
    const mouse = st_modeplan(1, 1003, 1, 0, 1);
    const origin = st_modeplan(1, 6, 1, 0, 1);
    try std.testing.expectEqual(@as(c_int, mode_alt1049), alt.kind);
    try std.testing.expectEqual(@as(c_int, mouse_many), mouse.mouse_mode);
    try std.testing.expectEqual(@as(c_int, cursor_state_origin), origin.cursor_state_action);
    try std.testing.expectEqual(@as(c_int, 4), alt.platform.count);
    try std.testing.expectEqual(@as(c_int, platform_effect_cursor), alt.platform.effects[0].kind);
    try std.testing.expectEqual(@as(c_int, platform_effect_clear_screen), alt.platform.effects[1].kind);
    try std.testing.expectEqual(@as(c_int, platform_effect_swap_screen), alt.platform.effects[2].kind);
    try std.testing.expectEqual(@as(c_int, platform_effect_cursor), alt.platform.effects[3].kind);
}

test "mode adapter smoke keeps unknown classification" {
    const plan = st_modeplan(1, 9999, 1, 0, 1);
    try std.testing.expectEqual(@as(c_int, mode_private_unknown), plan.kind);
    try std.testing.expectEqual(@as(c_int, mode_ignore), st_modeplan(1, 1005, 1, 0, 1).kind);
}

test "mode adapter smoke keeps regular unknown classification" {
    const plan = st_modeplan(0, 99, 1, 0, 1);
    try std.testing.expectEqual(@as(c_int, mode_regular_unknown), plan.kind);
}

test "utf8 selector enables and disables utf8 bit" {
    try std.testing.expectEqual(@as(c_int, term_mode_utf8), (Utf8Selector{ .ascii = 'G' }).apply(0));
    try std.testing.expectEqual(@as(c_int, 0), (Utf8Selector{ .ascii = '@' }).apply(term_mode_utf8));
}

test "utf8 selector ignores unknown selector" {
    try std.testing.expectEqual(@as(c_int, 5), (Utf8Selector{ .ascii = 'x' }).apply(5));
}

test "mode exports utf8 and charset selectors" {
    try std.testing.expectEqual(@as(c_int, term_mode_utf8), st_tdefutf8plan('G', 0));
    try std.testing.expectEqual(@as(c_int, 0), st_tdefutf8plan('@', term_mode_utf8));
    try std.testing.expectEqual(@as(c_int, charset_graphic0), st_tdeftranplan('0'));
    try std.testing.expectEqual(@as(c_int, charset_usa), st_tdeftranplan('B'));
    try std.testing.expectEqual(@as(c_int, charset_unknown), st_tdeftranplan('x'));
}

test "charset selector maps supported charsets" {
    try std.testing.expectEqual(@as(c_int, charset_graphic0), (CharsetSelector{ .ascii = '0' }).value());
    try std.testing.expectEqual(@as(c_int, charset_usa), (CharsetSelector{ .ascii = 'B' }).value());
}

test "charset selector reports unknown selector" {
    try std.testing.expectEqual(@as(c_int, charset_unknown), (CharsetSelector{ .ascii = 'x' }).value());
}
