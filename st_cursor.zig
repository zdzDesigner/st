//! st_cursor.zig 负责 CSI 光标移动序列的目标位置规划。
//! [输入]: CSI mode、当前光标坐标、光标状态、滚动区域和参数数组。
//! [输出]: `ZigCursorPlan` / `ZigCursorMove`，描述相对移动、绝对移动或最终光标状态。
//! [副作用边界]: 不调用 `tmoveto(...)` / `tmoveato(...)`，不修改 `term.c`；C 侧 executor 负责真实移动。
//! [定位]: 收敛 `csihandle(...)` 的 CUU/CUD/CUP/HVP 等 cursor 分支，以及 `tmoveto(...)` 的 clamp 主体。

const std = @import("std");

pub const ZigCursorPlan = extern struct {
    kind: c_int,
    x: c_int,
    y: c_int,
};

pub const ZigCursorMove = extern struct {
    x: c_int,
    y: c_int,
    state: c_int,
};

pub const ZigNewlinePlan = extern struct {
    scroll: c_int,
    scroll_top: c_int,
    x: c_int,
    y: c_int,
};

const ZigGlyph = extern struct {
    u: u32,
    mode: c_ushort,
    fg: u32,
    bg: u32,
};

pub const ZigDrawCursorPlan = extern struct {
    cx: c_int,
    ocx: c_int,
    ocy: c_int,
};

pub const ZigCursorStorePlan = extern struct {
    action: c_int,
    slot: c_int,
};

pub const cursor_move_to = 0;
pub const cursor_move_to_abs = 1;
pub const cursor_unknown = 2;

const cursor_wrapnext = 1;
const cursor_origin = 2;
const cursor_save = 0;
const cursor_load = 1;
const cursor_store_none = 0;
const cursor_store_save = 1;
const cursor_store_load = 2;
const attr_wdummy: c_ushort = 1 << 10;

export fn st_plancursor(mode: c_char, x: c_int, y: c_int, arg: [*]const c_int, len: c_int) ZigCursorPlan {
    const args = arg[0..@intCast(len)];
    const arg0 = defaultArg(args, 0, 1);
    const arg1 = defaultArg(args, 1, 1);

    return switch (mode) {
        'A' => .{ .kind = cursor_move_to, .x = x, .y = y - arg0 },
        'B', 'e' => .{ .kind = cursor_move_to, .x = x, .y = y + arg0 },
        'C', 'a' => .{ .kind = cursor_move_to, .x = x + arg0, .y = y },
        'D' => .{ .kind = cursor_move_to, .x = x - arg0, .y = y },
        'E' => .{ .kind = cursor_move_to, .x = 0, .y = y + arg0 },
        'F' => .{ .kind = cursor_move_to, .x = 0, .y = y - arg0 },
        'G', '`' => .{ .kind = cursor_move_to, .x = arg0 - 1, .y = y },
        'H', 'f' => .{ .kind = cursor_move_to_abs, .x = arg1 - 1, .y = arg0 - 1 },
        'd' => .{ .kind = cursor_move_to_abs, .x = x, .y = arg0 - 1 },
        else => .{ .kind = cursor_unknown, .x = x, .y = y },
    };
}

export fn st_tmoveto(x: c_int, y: c_int, state: c_int, col: c_int, row: c_int, top: c_int, bot: c_int) ZigCursorMove {
    const min_y: c_int = if ((state & cursor_origin) != 0) top else 0;
    const max_y: c_int = if ((state & cursor_origin) != 0) bot else row - 1;

    return .{
        .x = limitInt(x, 0, col - 1),
        .y = limitInt(y, min_y, max_y),
        .state = state & ~@as(c_int, cursor_wrapnext),
    };
}

export fn st_tnewline(first_col: c_int, x: c_int, y: c_int, top: c_int, bot: c_int) ZigNewlinePlan {
    return .{
        .scroll = if (y == bot) 1 else 0,
        .scroll_top = top,
        .x = if (first_col != 0) 0 else x,
        .y = if (y == bot) y else y + 1,
    };
}

export fn st_treverseindex(x: c_int, y: c_int, top: c_int) ZigNewlinePlan {
    return .{
        .scroll = if (y == top) 1 else 0,
        .scroll_top = top,
        .x = x,
        .y = if (y == top) y else y - 1,
    };
}

export fn st_tmoveato_y(y: c_int, state: c_int, top: c_int) c_int {
    return y + if ((state & cursor_origin) != 0) top else 0;
}

export fn st_drawcursorplan(cx: c_int, current_y: c_int, ocx: c_int, ocy: c_int, col: c_int, row: c_int, lines: [*]const [*]const ZigGlyph) ZigDrawCursorPlan {
    var plan = ZigDrawCursorPlan{
        .cx = cx,
        .ocx = limitInt(ocx, 0, col - 1),
        .ocy = limitInt(ocy, 0, row - 1),
    };

    if ((lines[@intCast(plan.ocy)][@intCast(plan.ocx)].mode & attr_wdummy) != 0) {
        plan.ocx -= 1;
    }
    if ((lines[@intCast(current_y)][@intCast(plan.cx)].mode & attr_wdummy) != 0) {
        plan.cx -= 1;
    }
    return plan;
}

export fn st_drawregionline(dirty: c_int) c_int {
    return if (dirty != 0) 1 else 0;
}

export fn st_drawsearchscan(active: c_int) c_int {
    return if (active != 0) 1 else 0;
}

export fn st_drawcursoractive(scr: c_int) c_int {
    return if (scr == 0) 1 else 0;
}

export fn st_tcursorplan(mode: c_int, alt: c_int) ZigCursorStorePlan {
    return .{
        .action = switch (mode) {
            cursor_save => cursor_store_save,
            cursor_load => cursor_store_load,
            else => cursor_store_none,
        },
        .slot = if (alt != 0) 1 else 0,
    };
}

export fn st_tsetmodecursor(set: c_int) c_int {
    return if (set != 0) cursor_save else cursor_load;
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

test "plan A defaults to one line up" {
    const plan = st_plancursor('A', 7, 9, &[_]c_int{0}, 1);
    try std.testing.expectEqual(@as(c_int, cursor_move_to), plan.kind);
    try std.testing.expectEqual(@as(c_int, 7), plan.x);
    try std.testing.expectEqual(@as(c_int, 8), plan.y);
}

test "plan C moves right by explicit count" {
    const plan = st_plancursor('C', 7, 9, &[_]c_int{3}, 1);
    try std.testing.expectEqual(@as(c_int, cursor_move_to), plan.kind);
    try std.testing.expectEqual(@as(c_int, 10), plan.x);
    try std.testing.expectEqual(@as(c_int, 9), plan.y);
}

test "plan H uses absolute row and col" {
    const plan = st_plancursor('H', 7, 9, &[_]c_int{ 4, 6 }, 2);
    try std.testing.expectEqual(@as(c_int, cursor_move_to_abs), plan.kind);
    try std.testing.expectEqual(@as(c_int, 5), plan.x);
    try std.testing.expectEqual(@as(c_int, 3), plan.y);
}

test "plan d keeps column for vertical absolute move" {
    const plan = st_plancursor('d', 7, 9, &[_]c_int{2}, 1);
    try std.testing.expectEqual(@as(c_int, cursor_move_to_abs), plan.kind);
    try std.testing.expectEqual(@as(c_int, 7), plan.x);
    try std.testing.expectEqual(@as(c_int, 1), plan.y);
}

test "plan unknown mode reports unknown" {
    const plan = st_plancursor('?', 7, 9, &[_]c_int{}, 0);
    try std.testing.expectEqual(@as(c_int, cursor_unknown), plan.kind);
}

test "tmoveto clears wrapnext and clamps to full screen" {
    const move = st_tmoveto(99, -3, cursor_wrapnext, 10, 6, 2, 4);

    try std.testing.expectEqual(@as(c_int, 9), move.x);
    try std.testing.expectEqual(@as(c_int, 0), move.y);
    try std.testing.expectEqual(@as(c_int, 0), move.state);
}

test "tmoveto origin mode clamps to scroll region" {
    const move = st_tmoveto(4, 9, cursor_origin | cursor_wrapnext, 10, 6, 2, 4);

    try std.testing.expectEqual(@as(c_int, 4), move.x);
    try std.testing.expectEqual(@as(c_int, 4), move.y);
    try std.testing.expectEqual(@as(c_int, cursor_origin), move.state);
}

test "tnewline advances within scroll region" {
    const plan = st_tnewline(0, 5, 3, 1, 6);

    try std.testing.expectEqual(@as(c_int, 0), plan.scroll);
    try std.testing.expectEqual(@as(c_int, 5), plan.x);
    try std.testing.expectEqual(@as(c_int, 4), plan.y);
}

test "tnewline scrolls at bottom and honors first column" {
    const plan = st_tnewline(1, 5, 6, 1, 6);

    try std.testing.expectEqual(@as(c_int, 1), plan.scroll);
    try std.testing.expectEqual(@as(c_int, 1), plan.scroll_top);
    try std.testing.expectEqual(@as(c_int, 0), plan.x);
    try std.testing.expectEqual(@as(c_int, 6), plan.y);
}

test "treverseindex scrolls at top otherwise moves up" {
    const scroll = st_treverseindex(5, 2, 2);
    const move = st_treverseindex(5, 4, 2);

    try std.testing.expectEqual(@as(c_int, 1), scroll.scroll);
    try std.testing.expectEqual(@as(c_int, 2), scroll.y);
    try std.testing.expectEqual(@as(c_int, 0), move.scroll);
    try std.testing.expectEqual(@as(c_int, 3), move.y);
}

test "tmoveato y applies origin offset only in origin mode" {
    try std.testing.expectEqual(@as(c_int, 7), st_tmoveato_y(5, cursor_origin, 2));
    try std.testing.expectEqual(@as(c_int, 5), st_tmoveato_y(5, 0, 2));
}

test "draw cursor plan clamps old cursor and adjusts dummy cells" {
    var row0 = [_]ZigGlyph{
        .{ .u = '中', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '文', .mode = attr_wdummy, .fg = 0, .bg = 0 },
    };
    var row1 = [_]ZigGlyph{
        .{ .u = '测', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '试', .mode = attr_wdummy, .fg = 0, .bg = 0 },
    };
    const lines = [_][*]const ZigGlyph{ &row0, &row1 };
    const plan = st_drawcursorplan(1, 1, 9, 0, 2, 2, &lines);

    try std.testing.expectEqual(@as(c_int, 0), plan.cx);
    try std.testing.expectEqual(@as(c_int, 0), plan.ocx);
    try std.testing.expectEqual(@as(c_int, 0), plan.ocy);
}

test "draw region line follows dirty flag" {
    try std.testing.expectEqual(@as(c_int, 0), st_drawregionline(0));
    try std.testing.expectEqual(@as(c_int, 1), st_drawregionline(2));
}

test "draw plans gate search scan and cursor" {
    try std.testing.expectEqual(@as(c_int, 1), st_drawsearchscan(1));
    try std.testing.expectEqual(@as(c_int, 0), st_drawsearchscan(0));
    try std.testing.expectEqual(@as(c_int, 1), st_drawcursoractive(0));
    try std.testing.expectEqual(@as(c_int, 0), st_drawcursoractive(2));
}

test "tcursor plan maps mode and alt slot" {
    const save = st_tcursorplan(cursor_save, 1);
    const load = st_tcursorplan(cursor_load, 0);

    try std.testing.expectEqual(@as(c_int, cursor_store_save), save.action);
    try std.testing.expectEqual(@as(c_int, 1), save.slot);
    try std.testing.expectEqual(@as(c_int, cursor_store_load), load.action);
    try std.testing.expectEqual(@as(c_int, 0), load.slot);
}

test "tsetmode cursor action follows set flag" {
    try std.testing.expectEqual(@as(c_int, cursor_save), st_tsetmodecursor(1));
    try std.testing.expectEqual(@as(c_int, cursor_load), st_tsetmodecursor(0));
}
