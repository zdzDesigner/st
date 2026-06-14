//! st_line.zig 承载剩余 C 侧无副作用的行/选择区判断逻辑。
//! [输入]: C 侧传入只读 glyph 行、终端列数，以及 selection 的值拷贝字段。
//! [输出]: 行有效长度，或指定坐标是否落在当前 selection 内。
//! [副作用边界]: 不访问全局 `term` / `sel`，不修改 glyph、dirty、selection，也不做 IO/分配/X11 调用。
//! [定位]: 替代 `tlinelen(...)`、`tlinehistlen(...)` 的扫描主体、`selected(...)` 的纯判断主体，以及 `selnormalize(...)` 的 bounds 计算主体。

const std = @import("std");

const ZigGlyph = extern struct {
    u: u32,
    mode: c_ushort,
    fg: u32,
    bg: u32,
};

const ZigSelBounds = extern struct {
    nb_x: c_int,
    nb_y: c_int,
    ne_x: c_int,
    ne_y: c_int,
};

const attr_wrap: c_ushort = 1 << 8;
const sel_regular = 1;
const sel_empty = 1;
const sel_rectangular = 2;

export fn st_tlinelen(line: [*]const ZigGlyph, col: c_int) c_int {
    var i = col;

    if ((line[@intCast(i - 1)].mode & attr_wrap) != 0) return i;

    while (i > 0 and line[@intCast(i - 1)].u == ' ') {
        i -= 1;
    }

    return i;
}

export fn st_selected(x: c_int, y: c_int, mode: c_int, ob_x: c_int, sel_alt: c_int, alt_screen: c_int, sel_type: c_int, nb_x: c_int, nb_y: c_int, ne_x: c_int, ne_y: c_int) c_int {
    if (mode == sel_empty or ob_x == -1 or sel_alt != alt_screen) return 0;

    if (sel_type == sel_rectangular) {
        return if (between(y, nb_y, ne_y) and between(x, nb_x, ne_x)) 1 else 0;
    }

    return if (between(y, nb_y, ne_y) and (y != nb_y or x >= nb_x) and (y != ne_y or x <= ne_x)) 1 else 0;
}

export fn st_planselnormalize(sel_type: c_int, ob_x: c_int, ob_y: c_int, oe_x: c_int, oe_y: c_int) ZigSelBounds {
    var bounds: ZigSelBounds = .{
        .nb_x = 0,
        .nb_y = minInt(ob_y, oe_y),
        .ne_x = 0,
        .ne_y = maxInt(ob_y, oe_y),
    };

    if (sel_type == sel_regular and ob_y != oe_y) {
        bounds.nb_x = if (ob_y < oe_y) ob_x else oe_x;
        bounds.ne_x = if (ob_y < oe_y) oe_x else ob_x;
        return bounds;
    }

    bounds.nb_x = minInt(ob_x, oe_x);
    bounds.ne_x = maxInt(ob_x, oe_x);
    return bounds;
}

fn between(value: c_int, lower: c_int, upper: c_int) bool {
    return lower <= value and value <= upper;
}

fn minInt(a: c_int, b: c_int) c_int {
    return if (a < b) a else b;
}

fn maxInt(a: c_int, b: c_int) c_int {
    return if (a > b) a else b;
}

test "line length ignores trailing spaces" {
    const line = [_]ZigGlyph{
        .{ .u = '你', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '好', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
    };

    try std.testing.expectEqual(@as(c_int, 2), st_tlinelen(&line, line.len));
}

test "line length keeps wrapped full line" {
    const line = [_]ZigGlyph{
        .{ .u = '中', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = attr_wrap, .fg = 0, .bg = 0 },
    };

    try std.testing.expectEqual(@as(c_int, 2), st_tlinelen(&line, line.len));
}

test "regular selection matches inclusive endpoints" {
    try std.testing.expectEqual(@as(c_int, 1), st_selected(3, 2, 2, 0, 0, 0, 1, 1, 2, 5, 2));
    try std.testing.expectEqual(@as(c_int, 0), st_selected(6, 2, 2, 0, 0, 0, 1, 1, 2, 5, 2));
}

test "rectangular selection checks both axes" {
    try std.testing.expectEqual(@as(c_int, 1), st_selected(4, 3, 2, 0, 0, 0, sel_rectangular, 2, 1, 5, 4));
    try std.testing.expectEqual(@as(c_int, 0), st_selected(6, 3, 2, 0, 0, 0, sel_rectangular, 2, 1, 5, 4));
}

test "selection rejects inactive or alternate screen mismatch" {
    try std.testing.expectEqual(@as(c_int, 0), st_selected(1, 1, sel_empty, 0, 0, 0, 1, 0, 0, 2, 2));
    try std.testing.expectEqual(@as(c_int, 0), st_selected(1, 1, 2, 0, 1, 0, 1, 0, 0, 2, 2));
}

test "selection normalize keeps regular multiline edge columns" {
    const bounds = st_planselnormalize(sel_regular, 7, 4, 2, 9);

    try std.testing.expectEqual(@as(c_int, 7), bounds.nb_x);
    try std.testing.expectEqual(@as(c_int, 4), bounds.nb_y);
    try std.testing.expectEqual(@as(c_int, 2), bounds.ne_x);
    try std.testing.expectEqual(@as(c_int, 9), bounds.ne_y);
}

test "selection normalize sorts same line columns" {
    const bounds = st_planselnormalize(sel_regular, 8, 3, 2, 3);

    try std.testing.expectEqual(@as(c_int, 2), bounds.nb_x);
    try std.testing.expectEqual(@as(c_int, 3), bounds.nb_y);
    try std.testing.expectEqual(@as(c_int, 8), bounds.ne_x);
    try std.testing.expectEqual(@as(c_int, 3), bounds.ne_y);
}

test "selection normalize rectangular sorts both axes" {
    const bounds = st_planselnormalize(sel_rectangular, 8, 6, 2, 3);

    try std.testing.expectEqual(@as(c_int, 2), bounds.nb_x);
    try std.testing.expectEqual(@as(c_int, 3), bounds.nb_y);
    try std.testing.expectEqual(@as(c_int, 8), bounds.ne_x);
    try std.testing.expectEqual(@as(c_int, 6), bounds.ne_y);
}
