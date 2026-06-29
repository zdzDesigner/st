//! st_edit.zig 负责行内搬移、scroll region 和键盘滚动的纯规划。
//! [输入]: 当前光标位置、终端列数、scroll region、历史游标和键盘滚动参数。
//! [输出]: `ZigEditMove`、`ZigScrollPlan` 和 `ZigKScrollPlan`。
//! [副作用边界]: 不执行 memmove、scroll、clear；`tapplyedit(...)` 在 C 侧调用对应副作用函数。
//! [定位]: 支撑 C executor 的编辑副作用边界；CSI edit 顶层分类已收敛到 `st_csi.zig`。

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
    new_histi: c_int,
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

const TextSpan = struct {
    x: c_int,
    col: c_int,

    fn deleteChars(self: TextSpan, n: c_int) ZigEditMove {
        const count = limitInt(n, 0, self.col - self.x);
        return .{
            .dst = self.x,
            .src = self.x + count,
            .size = self.col - (self.x + count),
            .clear_x1 = self.col - count,
            .clear_x2 = self.col - 1,
        };
    }

    fn insertBlanks(self: TextSpan, n: c_int) ZigEditMove {
        const count = limitInt(n, 0, self.col - self.x);
        return .{
            .dst = self.x + count,
            .src = self.x,
            .size = self.col - (self.x + count),
            .clear_x1 = self.x,
            .clear_x2 = self.x + count - 1,
        };
    }
};

const LineRegion = struct {
    top: c_int,
    bot: c_int,

    fn contains(self: LineRegion, y: c_int) bool {
        return self.top <= y and y <= self.bot;
    }

    fn scroll(self: LineRegion, n: c_int, scr: c_int, histsize: c_int, scroll_up: bool, copyhist: bool, histi: c_int) ZigScrollPlan {
        const count = limitInt(n, 0, self.bot - self.top + 1);
        const new_scr = if (scroll_up and scr > 0 and scr < histsize)
            minInt(scr + count, histsize - 1)
        else
            scr;
        const delta: c_int = if (scroll_up) 1 else -1;
        const new_histi = if (copyhist and histsize > 0) @mod(histi + delta, histsize) else histi;
        return .{ .count = count, .new_scr = new_scr, .new_histi = new_histi };
    }
};

const KeyboardScroll = struct {
    n: c_int,
    row: c_int,
    scr: c_int,
    histsize: c_int,

    fn down(self: KeyboardScroll) ZigKScrollPlan {
        var count = if (self.n < 0) self.row + self.n else self.n;
        if (count > self.scr) count = self.scr;
        return if (self.scr > 0)
            .{ .run = 1, .new_scr = self.scr - count, .delta = -count }
        else
            .{ .run = 0, .new_scr = self.scr, .delta = 0 };
    }

    fn up(self: KeyboardScroll) ZigKScrollPlan {
        const count = if (self.n < 0) self.row + self.n else self.n;
        return if (self.scr <= self.histsize - count)
            .{ .run = 1, .new_scr = self.scr + count, .delta = count }
        else
            .{ .run = 0, .new_scr = self.scr, .delta = 0 };
    }
};

export fn st_tdeletechar(n: c_int, x: c_int, col: c_int) ZigEditMove {
    return (TextSpan{ .x = x, .col = col }).deleteChars(n);
}

export fn st_tinsertblank(n: c_int, x: c_int, col: c_int) ZigEditMove {
    return (TextSpan{ .x = x, .col = col }).insertBlanks(n);
}

export fn st_tscrollplan(n: c_int, orig: c_int, bot: c_int, scr: c_int, histsize: c_int, scroll_up: c_int, copyhist: c_int, histi: c_int) ZigScrollPlan {
    return (LineRegion{ .top = orig, .bot = bot }).scroll(n, scr, histsize, scroll_up != 0, copyhist != 0, histi);
}

export fn st_kscrolldownplan(n: c_int, row: c_int, scr: c_int) ZigKScrollPlan {
    return (KeyboardScroll{ .n = n, .row = row, .scr = scr, .histsize = 0 }).down();
}

export fn st_kscrollupplan(n: c_int, row: c_int, scr: c_int, histsize: c_int) ZigKScrollPlan {
    return (KeyboardScroll{ .n = n, .row = row, .scr = scr, .histsize = histsize }).up();
}

fn limitInt(value: c_int, lower: c_int, upper: c_int) c_int {
    if (value < lower) return lower;
    if (value > upper) return upper;
    return value;
}

fn minInt(a: c_int, b: c_int) c_int {
    return if (a < b) a else b;
}

test "delete char move clamps count" {
    const move = st_tdeletechar(99, 7, 10);
    try std.testing.expectEqual(ZigEditMove{ .dst = 7, .src = 10, .size = 0, .clear_x1 = 7, .clear_x2 = 9 }, move);
}

test "insert blank move computes source and clear range" {
    const move = st_tinsertblank(2, 3, 10);
    try std.testing.expectEqual(ZigEditMove{ .dst = 5, .src = 3, .size = 5, .clear_x1 = 3, .clear_x2 = 4 }, move);
}

test "scroll plan clamps count to scroll region" {
    const plan = st_tscrollplan(99, 3, 8, 0, 100, 0, 0, 7);

    try std.testing.expectEqual(@as(c_int, 6), plan.count);
    try std.testing.expectEqual(@as(c_int, 0), plan.new_scr);
    try std.testing.expectEqual(@as(c_int, 7), plan.new_histi);
}

test "scroll up plan advances scrollback view" {
    const plan = st_tscrollplan(5, 0, 9, 98, 100, 1, 1, 99);

    try std.testing.expectEqual(@as(c_int, 5), plan.count);
    try std.testing.expectEqual(@as(c_int, 99), plan.new_scr);
    try std.testing.expectEqual(@as(c_int, 0), plan.new_histi);
}

test "scroll down plan wraps history head backward" {
    const plan = st_tscrollplan(1, 0, 9, 0, 100, 0, 1, 0);

    try std.testing.expectEqual(@as(c_int, 99), plan.new_histi);
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
