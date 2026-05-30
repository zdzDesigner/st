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

fn defaultArg(args: []const c_int, index: usize, fallback: c_int) c_int {
    if (index >= args.len) return fallback;
    return if (args[index] == 0) fallback else args[index];
}

fn zeroRect() ZigClearRect {
    return .{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 0 };
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
