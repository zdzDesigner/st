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

const EraseCommand = struct {
    mode: c_char,
    arg: c_int,
    x: c_int,
    y: c_int,
    col: c_int,
    row: c_int,

    fn plan(self: EraseCommand) ZigErasePlan {
        var result: ZigErasePlan = .{
            .kind = erase_ok,
            .count = 0,
            .rects = std.mem.zeroes([2]ZigClearRect),
        };

        switch (self.mode) {
            'J' => switch (self.arg) {
                0 => {
                    addRect(&result, self.x, self.y, self.col - 1, self.y);
                    if (self.y < self.row - 1) addRect(&result, 0, self.y + 1, self.col - 1, self.row - 1);
                },
                1 => {
                    if (self.y > 1) addRect(&result, 0, 0, self.col - 1, self.y - 1);
                    addRect(&result, 0, self.y, self.x, self.y);
                },
                2 => addRect(&result, 0, 0, self.col - 1, self.row - 1),
                else => result.kind = erase_unknown,
            },
            'K' => switch (self.arg) {
                0 => addRect(&result, self.x, self.y, self.col - 1, self.y),
                1 => addRect(&result, 0, self.y, self.x, self.y),
                2 => addRect(&result, 0, self.y, self.col - 1, self.y),
                else => result.kind = erase_unknown,
            },
            else => result.kind = erase_unknown,
        }

        return result;
    }
};

const ClearRect = struct {
    rect: ZigClearRect,
    maxcol: c_int,
    row: c_int,

    fn normalized(self: ClearRect) ZigClearRect {
        var result = self.rect;

        if (result.x1 > result.x2) {
            const tmp = result.x1;
            result.x1 = result.x2;
            result.x2 = tmp;
        }
        if (result.y1 > result.y2) {
            const tmp = result.y1;
            result.y1 = result.y2;
            result.y2 = tmp;
        }

        result.x1 = limitInt(result.x1, 0, self.maxcol - 1);
        result.x2 = limitInt(result.x2, 0, self.maxcol - 1);
        result.y1 = limitInt(result.y1, 0, self.row - 1);
        result.y2 = limitInt(result.y2, 0, self.row - 1);
        return result;
    }
};

fn planErase(mode: c_char, arg0: c_int, x: c_int, y: c_int, col: c_int, row: c_int) ZigErasePlan {
    return (EraseCommand{ .mode = mode, .arg = arg0, .x = x, .y = y, .col = col, .row = row }).plan();
}

export fn st_tclearregionrect(x1: c_int, y1: c_int, x2: c_int, y2: c_int, maxcol: c_int, row: c_int) ZigClearRect {
    return (ClearRect{ .rect = .{
        .x1 = x1,
        .y1 = y1,
        .x2 = x2,
        .y2 = y2,
    }, .maxcol = maxcol, .row = row }).normalized();
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
    const plan = planErase('J', 0, 3, 4, 10, 8);
    try std.testing.expectEqual(@as(c_int, erase_ok), plan.kind);
    try std.testing.expectEqual(@as(c_int, 2), plan.count);
    try std.testing.expectEqual(ZigClearRect{ .x1 = 3, .y1 = 4, .x2 = 9, .y2 = 4 }, plan.rects[0]);
    try std.testing.expectEqual(ZigClearRect{ .x1 = 0, .y1 = 5, .x2 = 9, .y2 = 7 }, plan.rects[1]);
}

test "plan J1 skips upper block on first row semantics" {
    const plan = planErase('J', 1, 2, 1, 10, 8);
    try std.testing.expectEqual(@as(c_int, erase_ok), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.count);
    try std.testing.expectEqual(ZigClearRect{ .x1 = 0, .y1 = 1, .x2 = 2, .y2 = 1 }, plan.rects[0]);
}

test "plan K2 clears full line" {
    const plan = planErase('K', 2, 5, 6, 10, 8);
    try std.testing.expectEqual(@as(c_int, erase_ok), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.count);
    try std.testing.expectEqual(ZigClearRect{ .x1 = 0, .y1 = 6, .x2 = 9, .y2 = 6 }, plan.rects[0]);
}

test "plan unknown J arg reports unknown" {
    const plan = planErase('J', 9, 0, 0, 10, 8);
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
