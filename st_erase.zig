const std = @import("std");

pub const ZigClearRect = extern struct {
    x1: c_int,
    y1: c_int,
    x2: c_int,
    y2: c_int,
};

pub const ZigErasePlan = extern struct {
    kind: c_int,
    count: c_int,
    rects: [2]ZigClearRect,
};

pub const erase_ok = 0;
pub const erase_unknown = 1;

export fn st_planerase(mode: c_char, arg0: c_int, x: c_int, y: c_int, col: c_int, row: c_int) ZigErasePlan {
    var plan: ZigErasePlan = .{
        .kind = erase_ok,
        .count = 0,
        .rects = std.mem.zeroes([2]ZigClearRect),
    };

    switch (mode) {
        'J' => switch (arg0) {
            0 => {
                addRect(&plan, x, y, col - 1, y);
                if (y < row - 1) addRect(&plan, 0, y + 1, col - 1, row - 1);
            },
            1 => {
                if (y > 1) addRect(&plan, 0, 0, col - 1, y - 1);
                addRect(&plan, 0, y, x, y);
            },
            2 => addRect(&plan, 0, 0, col - 1, row - 1),
            else => plan.kind = erase_unknown,
        },
        'K' => switch (arg0) {
            0 => addRect(&plan, x, y, col - 1, y),
            1 => addRect(&plan, 0, y, x, y),
            2 => addRect(&plan, 0, y, col - 1, y),
            else => plan.kind = erase_unknown,
        },
        else => plan.kind = erase_unknown,
    }

    return plan;
}

fn addRect(plan: *ZigErasePlan, x1: c_int, y1: c_int, x2: c_int, y2: c_int) void {
    if (plan.count >= plan.rects.len) return;
    plan.rects[@intCast(plan.count)] = .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 };
    plan.count += 1;
}

test "plan J0 emits current line and below" {
    const plan = st_planerase('J', 0, 3, 4, 10, 8);
    try std.testing.expectEqual(@as(c_int, erase_ok), plan.kind);
    try std.testing.expectEqual(@as(c_int, 2), plan.count);
    try std.testing.expectEqual(ZigClearRect{ .x1 = 3, .y1 = 4, .x2 = 9, .y2 = 4 }, plan.rects[0]);
    try std.testing.expectEqual(ZigClearRect{ .x1 = 0, .y1 = 5, .x2 = 9, .y2 = 7 }, plan.rects[1]);
}

test "plan J1 skips upper block on first row semantics" {
    const plan = st_planerase('J', 1, 2, 1, 10, 8);
    try std.testing.expectEqual(@as(c_int, erase_ok), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.count);
    try std.testing.expectEqual(ZigClearRect{ .x1 = 0, .y1 = 1, .x2 = 2, .y2 = 1 }, plan.rects[0]);
}

test "plan K2 clears full line" {
    const plan = st_planerase('K', 2, 5, 6, 10, 8);
    try std.testing.expectEqual(@as(c_int, erase_ok), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.count);
    try std.testing.expectEqual(ZigClearRect{ .x1 = 0, .y1 = 6, .x2 = 9, .y2 = 6 }, plan.rects[0]);
}

test "plan unknown J arg reports unknown" {
    const plan = st_planerase('J', 9, 0, 0, 10, 8);
    try std.testing.expectEqual(@as(c_int, erase_unknown), plan.kind);
}
