//! st_line.zig 承载剩余 C 侧无副作用的行/列位置判断逻辑。
//! [输入]: C 侧传入只读 glyph 行、终端列数和 tab stops。
//! [输出]: 行有效长度、dump 输出范围、tab 跳转目标列。
//! [副作用边界]: 不访问全局 `term` / `sel`，不修改 glyph 或 dirty 状态，也不做 IO/分配/X11 调用。
//! [定位]: 替代 `tlinelen(...)`、`tputtab(...)` 和 `externalpipe(...)` 行输出计划。

const std = @import("std");
const line_core = @import("st_line_core.zig");
const model = @import("term_model.zig");
const search = @import("st_search.zig");

const ZigGlyph = extern struct {
    u: u32,
    mode: c_ushort,
    fg: u32,
    bg: u32,
};

const ZigDumpLinePlan = extern struct {
    write: c_int,
    last: c_int,
};

const ZigLineRange = extern struct {
    top: c_int,
    bot: c_int,
};

const ZigSearchStepPlan = search.ZigSearchStepPlan;
const ZigSearchJumpPlan = search.ZigSearchJumpPlan;
const ZigSearchDeletePlan = search.ZigSearchDeletePlan;
const ZigSearchMatch = search.SearchMatch;
const ZigSearchSnapshot = search.ZigSearchSnapshot;
const ZigSearchPromptResult = search.ZigSearchPromptResult;
const ZigSearchInputResult = search.ZigSearchInputResult;
const ZigSearchCursorResult = search.ZigSearchCursorResult;
const ZigSearchStateResult = search.ZigSearchStateResult;
const ZigSearchScanResult = search.ZigSearchScanResult;
const ZigSearchSetResult = search.ZigSearchSetResult;

const ZigExternalPipePlan = extern struct {
    kind: c_int,
    lastpos: c_int,
    newline: c_int,
};

const ZigHistoryLinePlan = extern struct {
    hist: c_int,
    index: c_int,
};

const attr_wrap = model.attr_wrap;
const externalpipe_break = @intFromEnum(line_core.ExternalPipeLineKind.break_line);
const externalpipe_skip = @intFromEnum(line_core.ExternalPipeLineKind.skip);
const externalpipe_write = @intFromEnum(line_core.ExternalPipeLineKind.write);

export fn st_tlinelen(line: [*]const ZigGlyph, col: c_int) c_int {
    return (line_core.Line(ZigGlyph){ .glyphs = line[0..@intCast(col)], .cols = col }).length();
}

export fn st_tputtab(x: c_int, col: c_int, n: c_int, tabs: [*]const c_int) c_int {
    return (line_core.TabStops{ .stops = tabs[0..@intCast(col)], .cols = col }).target(x, n);
}

export fn st_tattrset(lines: [*]const [*]const ZigGlyph, row: c_int, col: c_int, attr: c_int) c_int {
    return boolInt((line_core.Lines(ZigGlyph){ .rows = lines[0..@intCast(row)], .row_count = row, .cols = col }).hasAttr(attrMask(attr)));
}

export fn st_tlineattrset(line: [*]const ZigGlyph, col: c_int, attr: c_int) c_int {
    return boolInt((line_core.Line(ZigGlyph){ .glyphs = line[0..@intCast(col)], .cols = col }).hasAttr(attrMask(attr)));
}

export fn st_tdumplineplan(linelen: c_int, col: c_int) ZigDumpLinePlan {
    const plan = (line_core.VisualLine{ .len = linelen, .cols = col }).dump();
    return .{
        .write = boolInt(plan.write),
        .last = plan.last,
    };
}

export fn st_tsetdirtrange(top: c_int, bot: c_int, row: c_int) ZigLineRange {
    const range = (line_core.Viewport{ .rows = row }).dirtyRange(top, bot);
    return .{
        .top = range.top,
        .bot = range.bot,
    };
}

export fn st_tlinehistplan(y: c_int, histsize: c_int, rows: c_int) ZigHistoryLinePlan {
    const plan = search.historyLine(y, histsize, rows);
    return .{ .hist = boolInt(plan.hist), .index = plan.index };
}

export fn st_externalpipeplan(line: [*]const ZigGlyph, col: c_int) ZigExternalPipePlan {
    const glyphs = line[0..@intCast(col)];
    const linelen = (line_core.Line(ZigGlyph){ .glyphs = glyphs, .cols = col }).length();
    const plan = (line_core.VisualLine{ .len = linelen, .cols = col }).externalPipe();
    return .{
        .kind = @intFromEnum(plan.kind),
        .lastpos = plan.lastpos,
        .newline = if (plan.kind == .write and line_core.externalPipeWrap(glyphs[@intCast(plan.lastpos)].mode)) 1 else 0,
    };
}

fn attrMask(attr: c_int) c_ushort {
    return @truncate(@as(c_uint, @bitCast(attr)));
}

fn boolInt(value: bool) c_int {
    return if (value) 1 else 0;
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

test "tab move forward lands on next tab stop" {
    const tabs = [_]c_int{ 0, 0, 0, 0, 1, 0, 0, 0, 1, 0 };

    try std.testing.expectEqual(@as(c_int, 4), st_tputtab(2, tabs.len, 1, &tabs));
}

test "tab move backward lands on previous tab stop" {
    const tabs = [_]c_int{ 0, 0, 0, 0, 1, 0, 0, 0, 1, 0 };

    try std.testing.expectEqual(@as(c_int, 4), st_tputtab(7, tabs.len, -1, &tabs));
}

test "tab move clamps to terminal bounds" {
    const tabs = [_]c_int{ 0, 0, 0, 0, 1 };

    try std.testing.expectEqual(@as(c_int, 4), st_tputtab(4, tabs.len, 1, &tabs));
    try std.testing.expectEqual(@as(c_int, 0), st_tputtab(0, tabs.len, -1, &tabs));
}

test "attribute scan finds mode before excluded edge" {
    var row0 = [_]ZigGlyph{
        .{ .u = '中', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '文', .mode = 1 << 3, .fg = 0, .bg = 0 },
        .{ .u = '边', .mode = 0, .fg = 0, .bg = 0 },
    };
    var row1 = [_]ZigGlyph{
        .{ .u = '界', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '测', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '试', .mode = 0, .fg = 0, .bg = 0 },
    };
    const lines = [_][*]const ZigGlyph{ &row0, &row1 };

    try std.testing.expectEqual(@as(c_int, 1), st_tattrset(&lines, 2, 3, 1 << 3));
}

test "attribute scan preserves excluded last row and column" {
    var row0 = [_]ZigGlyph{
        .{ .u = '中', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '文', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '列', .mode = 1 << 3, .fg = 0, .bg = 0 },
    };
    var row1 = [_]ZigGlyph{
        .{ .u = '行', .mode = 1 << 3, .fg = 0, .bg = 0 },
        .{ .u = '测', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '试', .mode = 0, .fg = 0, .bg = 0 },
    };
    const lines = [_][*]const ZigGlyph{ &row0, &row1 };

    try std.testing.expectEqual(@as(c_int, 0), st_tattrset(&lines, 2, 3, 1 << 3));
}

test "line attribute scan matches non-edge column only" {
    var line = [_]ZigGlyph{
        .{ .u = '中', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '文', .mode = 1 << 3, .fg = 0, .bg = 0 },
        .{ .u = '边', .mode = 1 << 4, .fg = 0, .bg = 0 },
    };

    try std.testing.expectEqual(@as(c_int, 1), st_tlineattrset(&line, line.len, 1 << 3));
    try std.testing.expectEqual(@as(c_int, 0), st_tlineattrset(&line, line.len, 1 << 4));
}

test "dump line plan writes through last valid glyph" {
    const plan = st_tdumplineplan(3, 10);

    try std.testing.expectEqual(@as(c_int, 1), plan.write);
    try std.testing.expectEqual(@as(c_int, 2), plan.last);
}

test "dump line plan skips empty visual line" {
    const plan = st_tdumplineplan(0, 10);

    try std.testing.expectEqual(@as(c_int, 0), plan.write);
    try std.testing.expectEqual(@as(c_int, -1), plan.last);
}

test "set dirt range clamps to terminal rows" {
    const range = st_tsetdirtrange(-2, 99, 24);

    try std.testing.expectEqual(@as(c_int, 0), range.top);
    try std.testing.expectEqual(@as(c_int, 23), range.bot);
}

test "history line plan maps scrollback and live rows" {
    const hist_line = st_tlinehistplan(5, 10, 7);
    const live_line = st_tlinehistplan(6, 10, 7);

    try std.testing.expectEqual(@as(c_int, 1), hist_line.hist);
    try std.testing.expectEqual(@as(c_int, 5), hist_line.index);
    try std.testing.expectEqual(@as(c_int, 0), live_line.hist);
    try std.testing.expectEqual(@as(c_int, 0), live_line.index);
}

test "external pipe line plan handles break skip and write" {
    const blank = [_]ZigGlyph{ .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 }, .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 } };
    const plain = [_]ZigGlyph{ .{ .u = '你', .mode = 0, .fg = 0, .bg = 0 }, .{ .u = '好', .mode = 0, .fg = 0, .bg = 0 }, .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 } };
    const wrapped = [_]ZigGlyph{ .{ .u = '中', .mode = 0, .fg = 0, .bg = 0 }, .{ .u = '文', .mode = attr_wrap, .fg = 0, .bg = 0 } };

    try std.testing.expectEqual(@as(c_int, externalpipe_skip), st_externalpipeplan(&blank, blank.len).kind);
    try std.testing.expectEqual(@as(c_int, externalpipe_write), st_externalpipeplan(&plain, plain.len).kind);
    try std.testing.expectEqual(@as(c_int, 2), st_externalpipeplan(&plain, plain.len).lastpos);
    try std.testing.expectEqual(@as(c_int, 1), st_externalpipeplan(&wrapped, wrapped.len).newline);
}
