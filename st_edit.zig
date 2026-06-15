//! st_edit.zig 负责 CSI 编辑类动作的纯规划。
//! [输入]: CSI mode、参数数组、当前光标位置、终端列数和 scroll region。
//! [输出]: `ZigEditPlan` / `ZigEditMove`，描述插空白、删字符、滚动、插删行、清局部区域或行内搬移范围。
//! [副作用边界]: 不执行 memmove、scroll、clear；`tapplyedit(...)` 在 C 侧调用对应副作用函数。
//! [定位]: 收敛 `csihandle(...)` 中 `@/S/T/L/M/X/P` 等 edit 分支。

const std = @import("std");

pub const ZigClearRect = extern struct {
    x1: c_int,
    y1: c_int,
    x2: c_int,
    y2: c_int,
};

pub const ZigEditPlan = extern struct {
    kind: c_int,
    count: c_int,
    rect: ZigClearRect,
};

pub const ZigEditMove = extern struct {
    dst: c_int,
    src: c_int,
    size: c_int,
    clear_x1: c_int,
    clear_x2: c_int,
};

pub const ZigScrollPlan = extern struct {
    count: c_int,
    new_scr: c_int,
};

pub const ZigKScrollPlan = extern struct {
    run: c_int,
    new_scr: c_int,
    delta: c_int,
};

pub const edit_insert_blank = 0;
pub const edit_scroll_up = 1;
pub const edit_scroll_down = 2;
pub const edit_insert_blank_line = 3;
pub const edit_delete_line = 4;
pub const edit_clear_region = 5;
pub const edit_delete_char = 6;
pub const edit_unknown = 7;

export fn st_planedit(mode: c_char, arg: [*]const c_int, len: c_int, x: c_int, y: c_int) ZigEditPlan {
    const args = arg[0..@intCast(len)];
    const count = defaultArg(args, 0, 1);

    return switch (mode) {
        '@' => .{ .kind = edit_insert_blank, .count = count, .rect = zeroRect() },
        'S' => .{ .kind = edit_scroll_up, .count = count, .rect = zeroRect() },
        'T' => .{ .kind = edit_scroll_down, .count = count, .rect = zeroRect() },
        'L' => .{ .kind = edit_insert_blank_line, .count = count, .rect = zeroRect() },
        'M' => .{ .kind = edit_delete_line, .count = count, .rect = zeroRect() },
        'P' => .{ .kind = edit_delete_char, .count = count, .rect = zeroRect() },
        'X' => .{ .kind = edit_clear_region, .count = count, .rect = .{ .x1 = x, .y1 = y, .x2 = x + count - 1, .y2 = y } },
        else => .{ .kind = edit_unknown, .count = count, .rect = zeroRect() },
    };
}

export fn st_tdeletechar(n: c_int, x: c_int, col: c_int) ZigEditMove {
    const count = limitInt(n, 0, col - x);
    return .{
        .dst = x,
        .src = x + count,
        .size = col - (x + count),
        .clear_x1 = col - count,
        .clear_x2 = col - 1,
    };
}

export fn st_tinsertblank(n: c_int, x: c_int, col: c_int) ZigEditMove {
    const count = limitInt(n, 0, col - x);
    return .{
        .dst = x + count,
        .src = x,
        .size = col - (x + count),
        .clear_x1 = x,
        .clear_x2 = x + count - 1,
    };
}

export fn st_tlineinregion(y: c_int, top: c_int, bot: c_int) c_int {
    return if (top <= y and y <= bot) 1 else 0;
}

export fn st_tscrollplan(n: c_int, orig: c_int, bot: c_int, scr: c_int, histsize: c_int, scroll_up: c_int) ZigScrollPlan {
    const count = limitInt(n, 0, bot - orig + 1);
    const new_scr = if (scroll_up != 0 and scr > 0 and scr < histsize)
        minInt(scr + count, histsize - 1)
    else
        scr;
    return .{ .count = count, .new_scr = new_scr };
}

export fn st_kscrolldownplan(n: c_int, row: c_int, scr: c_int) ZigKScrollPlan {
    var count = if (n < 0) row + n else n;
    if (count > scr) count = scr;
    return if (scr > 0)
        .{ .run = 1, .new_scr = scr - count, .delta = -count }
    else
        .{ .run = 0, .new_scr = scr, .delta = 0 };
}

export fn st_kscrollupplan(n: c_int, row: c_int, scr: c_int, histsize: c_int) ZigKScrollPlan {
    const count = if (n < 0) row + n else n;
    return if (scr <= histsize - count)
        .{ .run = 1, .new_scr = scr + count, .delta = count }
    else
        .{ .run = 0, .new_scr = scr, .delta = 0 };
}

fn defaultArg(args: []const c_int, index: usize, fallback: c_int) c_int {
    if (index >= args.len) return fallback;
    return if (args[index] == 0) fallback else args[index];
}

fn zeroRect() ZigClearRect {
    return .{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 0 };
}

fn limitInt(value: c_int, lower: c_int, upper: c_int) c_int {
    if (value < lower) return lower;
    if (value > upper) return upper;
    return value;
}

fn minInt(a: c_int, b: c_int) c_int {
    return if (a < b) a else b;
}

test "plan insert blank defaults to one" {
    const plan = st_planedit('@', &[_]c_int{0}, 1, 3, 4);
    try std.testing.expectEqual(@as(c_int, edit_insert_blank), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.count);
}

test "plan scroll up keeps explicit count" {
    const plan = st_planedit('S', &[_]c_int{3}, 1, 3, 4);
    try std.testing.expectEqual(@as(c_int, edit_scroll_up), plan.kind);
    try std.testing.expectEqual(@as(c_int, 3), plan.count);
}

test "plan erase char computes clear region" {
    const plan = st_planedit('X', &[_]c_int{4}, 1, 5, 6);
    try std.testing.expectEqual(@as(c_int, edit_clear_region), plan.kind);
    try std.testing.expectEqual(@as(c_int, 4), plan.count);
    try std.testing.expectEqual(ZigClearRect{ .x1 = 5, .y1 = 6, .x2 = 8, .y2 = 6 }, plan.rect);
}

test "plan delete char defaults to one" {
    const plan = st_planedit('P', &[_]c_int{}, 0, 5, 6);
    try std.testing.expectEqual(@as(c_int, edit_delete_char), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.count);
}

test "plan unknown mode reports unknown" {
    const plan = st_planedit('?', &[_]c_int{}, 0, 0, 0);
    try std.testing.expectEqual(@as(c_int, edit_unknown), plan.kind);
}

test "delete char move clamps count" {
    const move = st_tdeletechar(99, 7, 10);
    try std.testing.expectEqual(ZigEditMove{ .dst = 7, .src = 10, .size = 0, .clear_x1 = 7, .clear_x2 = 9 }, move);
}

test "insert blank move computes source and clear range" {
    const move = st_tinsertblank(2, 3, 10);
    try std.testing.expectEqual(ZigEditMove{ .dst = 5, .src = 3, .size = 5, .clear_x1 = 3, .clear_x2 = 4 }, move);
}

test "line region check is inclusive" {
    try std.testing.expectEqual(@as(c_int, 1), st_tlineinregion(3, 3, 6));
    try std.testing.expectEqual(@as(c_int, 1), st_tlineinregion(6, 3, 6));
    try std.testing.expectEqual(@as(c_int, 0), st_tlineinregion(7, 3, 6));
}

test "scroll plan clamps count to scroll region" {
    const plan = st_tscrollplan(99, 3, 8, 0, 100, 0);

    try std.testing.expectEqual(@as(c_int, 6), plan.count);
    try std.testing.expectEqual(@as(c_int, 0), plan.new_scr);
}

test "scroll up plan advances scrollback view" {
    const plan = st_tscrollplan(5, 0, 9, 98, 100, 1);

    try std.testing.expectEqual(@as(c_int, 5), plan.count);
    try std.testing.expectEqual(@as(c_int, 99), plan.new_scr);
}

test "keyboard scroll down clamps to current scroll" {
    const plan = st_kscrolldownplan(9, 24, 4);

    try std.testing.expectEqual(@as(c_int, 1), plan.run);
    try std.testing.expectEqual(@as(c_int, 0), plan.new_scr);
    try std.testing.expectEqual(@as(c_int, -4), plan.delta);
}

test "keyboard scroll up preserves hist bound" {
    const plan = st_kscrollupplan(5, 24, 90, 100);

    try std.testing.expectEqual(@as(c_int, 1), plan.run);
    try std.testing.expectEqual(@as(c_int, 95), plan.new_scr);
    try std.testing.expectEqual(@as(c_int, 5), plan.delta);
}
