//! st_erase.zig 负责 CSI ED/EL 清屏清行和清理矩形边界的纯规划。
//! [输入]: CSI mode、参数、当前光标位置、清理矩形和终端尺寸。
//! [输出]: `ZigErasePlan` / `ZigClearRect`，描述需要清理的一个或多个矩形区域。
//! [副作用边界]: 不调用 `tclearregion(...)`，不修改 dirty 行或 selection；这些真实副作用保留在 C executor。
//! [定位]: 服务 `csihandle(...)` 中的 `J/K` 分支和 `tclearregion(...)` 边界规划，让 Zig 决定清哪里，C 决定如何清。

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

export fn st_tclearregionrect(x1: c_int, y1: c_int, x2: c_int, y2: c_int, maxcol: c_int, row: c_int) ZigClearRect {
    var rect = ZigClearRect{
        .x1 = x1,
        .y1 = y1,
        .x2 = x2,
        .y2 = y2,
    };

    if (rect.x1 > rect.x2) {
        const tmp = rect.x1;
        rect.x1 = rect.x2;
        rect.x2 = tmp;
    }
    if (rect.y1 > rect.y2) {
        const tmp = rect.y1;
        rect.y1 = rect.y2;
        rect.y2 = tmp;
    }

    rect.x1 = limitInt(rect.x1, 0, maxcol - 1);
    rect.x2 = limitInt(rect.x2, 0, maxcol - 1);
    rect.y1 = limitInt(rect.y1, 0, row - 1);
    rect.y2 = limitInt(rect.y2, 0, row - 1);
    return rect;
}

fn addRect(plan: *ZigErasePlan, x1: c_int, y1: c_int, x2: c_int, y2: c_int) void {
    if (plan.count >= plan.rects.len) return;
    plan.rects[@intCast(plan.count)] = .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 };
    plan.count += 1;
}

fn limitInt(value: c_int, lower: c_int, upper: c_int) c_int {
    if (value < lower) return lower;
    if (value > upper) return upper;
    return value;
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

test "clear region rect sorts and clamps bounds" {
    const rect = st_tclearregionrect(12, 9, -2, 3, 10, 8);

    try std.testing.expectEqual(ZigClearRect{ .x1 = 0, .y1 = 3, .x2 = 9, .y2 = 7 }, rect);
}

test "clear region rect keeps ordered in-range bounds" {
    const rect = st_tclearregionrect(2, 3, 5, 6, 10, 8);

    try std.testing.expectEqual(ZigClearRect{ .x1 = 2, .y1 = 3, .x2 = 5, .y2 = 6 }, rect);
}
