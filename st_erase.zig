//! st_erase.zig 负责清理矩形边界归一化。
//! [输入]: C executor 传入的清理矩形和终端尺寸。
//! [输出]: `ZigClearRect`，描述排序并 clamp 后的清理范围。
//! [副作用边界]: 不调用 `tclearregion(...)`，不修改 dirty 行或 selection；这些真实副作用保留在 C executor。
//! [定位]: 支撑 `tclearregion(...)` 边界规划；CSI erase 顶层分类已收敛到 `st_csi.zig`。

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

export fn st_tclearregionrect(x1: c_int, y1: c_int, x2: c_int, y2: c_int, maxcol: c_int, row: c_int) ZigClearRect {
    return (ClearRect{ .rect = .{
        .x1 = x1,
        .y1 = y1,
        .x2 = x2,
        .y2 = y2,
    }, .maxcol = maxcol, .row = row }).normalized();
}

fn limitInt(value: c_int, lower: c_int, upper: c_int) c_int {
    if (value < lower) return lower;
    if (value > upper) return upper;
    return value;
}

test "clear region rect sorts and clamps bounds" {
    const rect = st_tclearregionrect(12, 9, -2, 3, 10, 8);

    try std.testing.expectEqual(ZigClearRect{ .x1 = 0, .y1 = 3, .x2 = 9, .y2 = 7 }, rect);
}

test "clear region rect keeps ordered in-range bounds" {
    const rect = st_tclearregionrect(2, 3, 5, 6, 10, 8);

    try std.testing.expectEqual(ZigClearRect{ .x1 = 2, .y1 = 3, .x2 = 5, .y2 = 6 }, rect);
}
