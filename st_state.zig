//! st_state.zig 负责 CSI 状态类序列的纯规划。
//! [输入]: CSI mode、private marker、参数数组、终端行数、scroll region 边界和 resize 尺寸。
//! [输出]: `ZigStatePlan` / `ZigScrollRegion` / `ZigResizePlan`，描述设置滚动区域、保存光标、恢复光标、最终 scroll region 或 resize 边界。
//! [副作用边界]: 不调用 `tsetscroll(...)` / `tcursor(...)`，不修改光标或 scroll region；这些保留在 C executor。
//! [定位]: 收敛 `csihandle(...)` 中 `r/s/u` 分支和 `tsetscroll(...)` 的 clamp 主体，并保持 unknown 路径由 C 处理。

const std = @import("std");

pub const ZigStatePlan = extern struct {
    kind: c_int,
    top: c_int,
    bottom: c_int,
};

pub const ZigScrollRegion = extern struct {
    top: c_int,
    bottom: c_int,
};

pub const ZigResizePlan = extern struct {
    invalid: c_int,
    requested_col: c_int,
    alloc_col: c_int,
    base_maxcol: c_int,
    minrow: c_int,
    mincol: c_int,
    slide_count: c_int,
    tail_start: c_int,
};

pub const ZigResetPlan = extern struct {
    cursor_attr_mode: c_ushort,
    cursor_fg: u32,
    cursor_bg: u32,
    cursor_x: c_int,
    cursor_y: c_int,
    cursor_state: c_int,
    top: c_int,
    bot: c_int,
    mode: c_int,
    charset: c_int,
    trantbl: c_int,
};

pub const state_unknown = 0;
pub const state_set_scroll = 1;
pub const state_save_cursor = 2;
pub const state_load_cursor = 3;

const attr_null: c_ushort = 0;
const cursor_default = 0;
const mode_wrap = 1 << 0;
const mode_utf8 = 1 << 6;
const charset_usa = 3;

export fn st_planstate(mode: c_char, priv: c_int, arg: [*]const c_int, len: c_int, row: c_int) ZigStatePlan {
    const args = arg[0..@intCast(len)];

    return switch (mode) {
        'r' => if (priv != 0)
            .{ .kind = state_unknown, .top = 0, .bottom = 0 }
        else
            .{
                .kind = state_set_scroll,
                .top = defaultArg(args, 0, 1) - 1,
                .bottom = defaultArg(args, 1, row) - 1,
            },
        's' => .{ .kind = state_save_cursor, .top = 0, .bottom = 0 },
        'u' => .{ .kind = state_load_cursor, .top = 0, .bottom = 0 },
        else => .{ .kind = state_unknown, .top = 0, .bottom = 0 },
    };
}

export fn st_tsetscroll(t: c_int, b: c_int, row: c_int) ZigScrollRegion {
    var top = limitInt(t, 0, row - 1);
    var bottom = limitInt(b, 0, row - 1);

    if (top > bottom) {
        const tmp = top;
        top = bottom;
        bottom = tmp;
    }

    return .{ .top = top, .bottom = bottom };
}

export fn st_tresizeplan(requested_col: c_int, requested_row: c_int, current_col: c_int, current_row: c_int, current_maxcol: c_int, cursor_y: c_int) ZigResizePlan {
    const base_maxcol = if (current_maxcol == 0) current_col else current_maxcol;
    const alloc_col = maxInt(requested_col, base_maxcol);
    const slide_count = if (cursor_y >= requested_row) cursor_y - requested_row + 1 else 0;

    return .{
        .invalid = if (alloc_col < 1 or requested_row < 1) 1 else 0,
        .requested_col = requested_col,
        .alloc_col = alloc_col,
        .base_maxcol = base_maxcol,
        .minrow = minInt(requested_row, current_row),
        .mincol = minInt(alloc_col, base_maxcol),
        .slide_count = slide_count,
        .tail_start = slide_count + requested_row,
    };
}

export fn st_tresizetabstart(tabs: [*]const c_int, old_col: c_int, tabspaces: c_int) c_int {
    if (old_col <= 0) return tabspaces;

    var index = old_col - 1;
    while (index > 0 and tabs[@intCast(index)] == 0) {
        index -= 1;
    }
    return index + tabspaces;
}

export fn st_tresetplan(default_fg: u32, default_bg: u32, row: c_int) ZigResetPlan {
    return .{
        .cursor_attr_mode = attr_null,
        .cursor_fg = default_fg,
        .cursor_bg = default_bg,
        .cursor_x = 0,
        .cursor_y = 0,
        .cursor_state = cursor_default,
        .top = 0,
        .bot = row - 1,
        .mode = mode_wrap | mode_utf8,
        .charset = 0,
        .trantbl = charset_usa,
    };
}

fn defaultArg(args: []const c_int, index: usize, fallback: c_int) c_int {
    if (index >= args.len) return fallback;
    return if (args[index] == 0) fallback else args[index];
}

fn limitInt(value: c_int, lower: c_int, upper: c_int) c_int {
    if (value < lower) return lower;
    if (value > upper) return upper;
    return value;
}

fn minInt(a: c_int, b: c_int) c_int {
    return if (a < b) a else b;
}

fn maxInt(a: c_int, b: c_int) c_int {
    return if (a > b) a else b;
}

test "plan r defaults to full screen scroll region" {
    const plan = st_planstate('r', 0, &[_]c_int{ 0, 0 }, 2, 24);
    try std.testing.expectEqual(@as(c_int, state_set_scroll), plan.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.top);
    try std.testing.expectEqual(@as(c_int, 23), plan.bottom);
}

test "plan r uses explicit bounds" {
    const plan = st_planstate('r', 0, &[_]c_int{ 2, 10 }, 2, 24);
    try std.testing.expectEqual(@as(c_int, state_set_scroll), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.top);
    try std.testing.expectEqual(@as(c_int, 9), plan.bottom);
}

test "plan r with private marker is unknown" {
    const plan = st_planstate('r', 1, &[_]c_int{ 2, 10 }, 2, 24);
    try std.testing.expectEqual(@as(c_int, state_unknown), plan.kind);
}

test "plan s saves cursor" {
    const plan = st_planstate('s', 0, &[_]c_int{}, 0, 24);
    try std.testing.expectEqual(@as(c_int, state_save_cursor), plan.kind);
}

test "plan u loads cursor" {
    const plan = st_planstate('u', 0, &[_]c_int{}, 0, 24);
    try std.testing.expectEqual(@as(c_int, state_load_cursor), plan.kind);
}

test "tsetscroll clamps to terminal rows" {
    const region = st_tsetscroll(-3, 99, 24);

    try std.testing.expectEqual(@as(c_int, 0), region.top);
    try std.testing.expectEqual(@as(c_int, 23), region.bottom);
}

test "tsetscroll sorts inverted bounds after clamp" {
    const region = st_tsetscroll(20, 4, 24);

    try std.testing.expectEqual(@as(c_int, 4), region.top);
    try std.testing.expectEqual(@as(c_int, 20), region.bottom);
}

test "tresize plan preserves requested and alloc columns" {
    const plan = st_tresizeplan(80, 24, 100, 30, 0, 10);

    try std.testing.expectEqual(@as(c_int, 0), plan.invalid);
    try std.testing.expectEqual(@as(c_int, 80), plan.requested_col);
    try std.testing.expectEqual(@as(c_int, 100), plan.alloc_col);
    try std.testing.expectEqual(@as(c_int, 100), plan.base_maxcol);
    try std.testing.expectEqual(@as(c_int, 24), plan.minrow);
    try std.testing.expectEqual(@as(c_int, 100), plan.mincol);
}

test "tresize plan computes slide and tail free bounds" {
    const plan = st_tresizeplan(120, 20, 100, 30, 100, 25);

    try std.testing.expectEqual(@as(c_int, 6), plan.slide_count);
    try std.testing.expectEqual(@as(c_int, 26), plan.tail_start);
}

test "tresize tab start continues after previous tab" {
    const tabs = [_]c_int{ 0, 0, 0, 0, 1, 0, 0, 0 };

    try std.testing.expectEqual(@as(c_int, 8), st_tresizetabstart(&tabs, tabs.len, 4));
}

test "tresize tab start falls back from no previous tab" {
    const tabs = [_]c_int{ 0, 0, 0, 0 };

    try std.testing.expectEqual(@as(c_int, 4), st_tresizetabstart(&tabs, tabs.len, 4));
}

test "treset plan sets default terminal state" {
    const plan = st_tresetplan(7, 8, 24);

    try std.testing.expectEqual(@as(c_ushort, attr_null), plan.cursor_attr_mode);
    try std.testing.expectEqual(@as(u32, 7), plan.cursor_fg);
    try std.testing.expectEqual(@as(u32, 8), plan.cursor_bg);
    try std.testing.expectEqual(@as(c_int, 0), plan.top);
    try std.testing.expectEqual(@as(c_int, 23), plan.bot);
    try std.testing.expectEqual(@as(c_int, mode_wrap | mode_utf8), plan.mode);
    try std.testing.expectEqual(@as(c_int, charset_usa), plan.trantbl);
}
