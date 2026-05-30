const std = @import("std");

pub const ZigCursorPlan = extern struct {
    kind: c_int,
    x: c_int,
    y: c_int,
};

pub const cursor_move_to = 0;
pub const cursor_move_to_abs = 1;
pub const cursor_unknown = 2;

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

fn defaultArg(args: []const c_int, index: usize, fallback: c_int) c_int {
    if (index >= args.len) return fallback;
    return if (args[index] == 0) fallback else args[index];
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
    const plan = st_plancursor('H', 7, 9, &[_]c_int{4, 6}, 2);
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
