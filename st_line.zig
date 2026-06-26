//! st_line.zig 承载剩余 C 侧无副作用的行/选择区/列位置判断逻辑。
//! [输入]: C 侧传入只读 glyph 行、终端列数、tab stops，以及 selection 的值拷贝字段。
//! [输出]: 行有效长度、dump 输出范围、tab 跳转目标列，或指定坐标是否落在当前 selection 内。
//! [副作用边界]: 不访问全局 `term` / `sel`，不修改 glyph、dirty、selection，也不做 IO/分配/X11 调用。
//! [定位]: 替代 `tlinelen(...)`、`tputtab(...)`、`externalpipe(...)` 行输出计划、`selected(...)` 的纯判断主体，以及 `selnormalize(...)` 的 bounds 计算主体。

const std = @import("std");
const line_core = @import("st_line_core.zig");
const model = @import("term_model.zig");
const selection = @import("st_selection.zig");
const search = @import("st_search.zig");

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

const ZigDumpLinePlan = extern struct {
    write: c_int,
    last: c_int,
};

const ZigLineRange = extern struct {
    top: c_int,
    bot: c_int,
};

const ZigSelectionSnapshot = selection.ZigSelectionSnapshot;
const ZigSelectionStateResult = selection.ZigSelectionStateResult;
const ZigSelSnapWordStep = selection.ZigSelSnapWordStep;
const ZigSelSnapWordIterRequest = selection.ZigSelSnapWordIterRequest;
const ZigSelSnapWordReaderSnapshot = selection.ZigSelSnapWordReaderSnapshot;
const ZigSelSnapLineStep = selection.ZigSelSnapLineStep;
const ZigGetSelExecPlan = selection.ZigGetSelExecPlan;

const ZigSearchStepPlan = search.ZigSearchStepPlan;
const ZigSearchJumpPlan = search.ZigSearchJumpPlan;
const ZigSearchDeletePlan = search.ZigSearchDeletePlan;
const ZigSearchMatch = search.SearchMatch;
const ZigSearchLinePlan = search.ZigSearchLinePlan;
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
const attr_wdummy = model.attr_wdummy;
const sel_regular = @intFromEnum(selection.SelectionType.regular);
const sel_empty = @intFromEnum(selection.SelectionMode.empty);
const sel_rectangular = @intFromEnum(selection.SelectionType.rectangular);
const sel_scroll_none = @intFromEnum(selection.ScrollAction.none);
const sel_scroll_clear = @intFromEnum(selection.ScrollAction.clear);
const sel_scroll_normalize = @intFromEnum(selection.ScrollAction.normalize);
const sel_snap_word_break = @intFromEnum(selection.SnapWordAction.stop);
const sel_snap_word_accept = @intFromEnum(selection.SnapWordAction.accept);
const sel_snap_line_stop = @intFromEnum(selection.SnapLineAction.stop);
const sel_snap_line_move = @intFromEnum(selection.SnapLineAction.move);
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

export fn st_selclearplan(ob_x: c_int) c_int {
    return selection.zigSelclearplan(ob_x);
}

export fn st_selstartupdate(snapshot: ZigSelectionSnapshot, col: c_int, row: c_int, snap: c_int, alt_screen: c_int) ZigSelectionStateResult {
    return selection.zigSelstartupdate(snapshot, col, row, snap, alt_screen);
}

export fn st_selextendupdate(snapshot: ZigSelectionSnapshot, col: c_int, row: c_int, sel_type: c_int, done: c_int) ZigSelectionStateResult {
    return selection.zigSelextendupdate(snapshot, col, row, sel_type, done);
}

export fn st_selscrollupdate(snapshot: ZigSelectionSnapshot, orig: c_int, top: c_int, bot: c_int, delta: c_int) ZigSelectionStateResult {
    return selection.zigSelscrollupdate(snapshot, orig, top, bot, delta);
}

export fn st_selnormalizeupdate(snapshot: ZigSelectionSnapshot, col: c_int, start_len: c_int, end_len: c_int) ZigSelectionStateResult {
    return selection.zigSelnormalizeupdate(snapshot, col, start_len, end_len);
}

export fn st_selsnaplinex(direction: c_int, col: c_int) c_int {
    return selection.snapLineX(direction, col);
}

export fn st_selsnaplinestep(y: c_int, direction: c_int, row: c_int, wrapped: c_int) ZigSelSnapLineStep {
    return selection.zigSelsnaplinestep(y, direction, row, wrapped);
}

export fn st_selsnapworditerrequest(x: c_int, y: c_int, direction: c_int, col: c_int, row: c_int, prevdelim: c_int, prevrune: u32) ZigSelSnapWordIterRequest {
    return selection.zigSelsnapworditerrequest(x, y, direction, col, row, prevdelim, prevrune);
}

export fn st_selsnapworditerresolve(request: ZigSelSnapWordIterRequest, prevdelim: c_int, prevrune: u32, reader: ZigSelSnapWordReaderSnapshot) ZigSelSnapWordStep {
    return selection.zigSelsnapworditerresolve(request, prevdelim, prevrune, reader);
}

export fn st_selected(x: c_int, y: c_int, mode: c_int, ob_x: c_int, sel_alt: c_int, alt_screen: c_int, sel_type: c_int, nb_x: c_int, nb_y: c_int, ne_x: c_int, ne_y: c_int) c_int {
    return selection.zigSelected(x, y, mode, ob_x, sel_alt, alt_screen, sel_type, nb_x, nb_y, ne_x, ne_y);
}

export fn st_searchmatchlist(matches: ?[*]const ZigSearchMatch, nmatches: c_int, active: c_int, current: c_int, term_scr: c_int, x: c_int, y: c_int) c_int {
    return search.zigSearchmatchlist(matches, nmatches, active, current, term_scr, x, y);
}

export fn st_searchcurrentmatch(matches: ?[*]const ZigSearchMatch, nmatches: c_int, active: c_int, current: c_int, term_scr: c_int, x: c_int, y: c_int) c_int {
    return search.zigSearchcurrentmatch(matches, nmatches, active, current, term_scr, x, y);
}

export fn st_searchlineplan(line: [*]const ZigGlyph, start_x: c_int, col: c_int, query: [*]const u32, qlen: c_int, nmatches: c_int, cap: c_int, y: c_int, scr: c_int) ZigSearchLinePlan {
    return search.zigSearchlineplan(@ptrCast(line), start_x, col, query, qlen, nmatches, cap, y, scr);
}

export fn st_tlinehistplan(y: c_int, histsize: c_int, rows: c_int) ZigHistoryLinePlan {
    const plan = search.historyLine(y, histsize, rows);
    return .{ .hist = boolInt(plan.hist), .index = plan.index };
}

export fn st_searchstep(active: c_int, nmatches: c_int, current: c_int, direction: c_int) ZigSearchStepPlan {
    return search.zigSearchstep(active, nmatches, current, direction);
}

export fn st_searchjumpplan(active: c_int, current: c_int, nmatches: c_int, term_scr: c_int, match_scr: c_int) ZigSearchJumpPlan {
    return search.zigSearchjumpplan(active, current, nmatches, term_scr, match_scr);
}

export fn st_searchcursorupdate(snapshot: ZigSearchSnapshot, input: [*]const u8, action: c_int) ZigSearchCursorResult {
    return search.zigSearchcursorupdate(snapshot, input, action);
}

export fn st_searchstateupdate(snapshot: ZigSearchSnapshot, action: c_int) ZigSearchStateResult {
    return search.zigSearchstateupdate(snapshot, action);
}

export fn st_searchscanupdate(snapshot: ZigSearchSnapshot, nmatches: c_int, current: c_int) ZigSearchScanResult {
    return search.zigSearchscanupdate(snapshot, nmatches, current);
}

export fn st_searchdeleteplan(start: usize, end: usize, inputlen: usize) ZigSearchDeletePlan {
    return search.zigSearchdeleteplan(start, end, inputlen);
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

export fn st_searchpromptupdate(snapshot: ZigSearchSnapshot) ZigSearchPromptResult {
    return search.zigSearchpromptupdate(snapshot);
}

export fn st_searchinputupdate(snapshot: ZigSearchSnapshot, add_len: usize) ZigSearchInputResult {
    return search.zigSearchinputupdate(snapshot, add_len);
}

export fn st_searchsetupdate(snapshot: ZigSearchSnapshot, query_len: usize, qlen: c_int) ZigSearchSetResult {
    return search.zigSearchsetupdate(snapshot, query_len, qlen);
}

export fn st_getselexecplan(sel_type: c_int, nb_x: c_int, nb_y: c_int, ne_x: c_int, ne_y: c_int, y: c_int, col: c_int, line: [*]const ZigGlyph, utf_siz: c_int) ZigGetSelExecPlan {
    return selection.zigGetselexecplan(sel_type, nb_x, nb_y, ne_x, ne_y, y, col, @ptrCast(line), utf_siz);
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

test "selection scroll clears split selection" {
    const plan = st_selscrollupdate(.{ .mode = sel_empty + 1, .selection_type = sel_regular, .alt = 0, .snap = 0, .ob_x = 0, .ob_y = 2, .oe_x = 3, .oe_y = 6, .nb_x = 0, .nb_y = 2, .ne_x = 3, .ne_y = 6 }, 4, 0, 9, 1);

    try std.testing.expectEqual(@as(c_int, 1), plan.effect.clear);
}

test "selection scroll moves and normalizes selection inside region" {
    const plan = st_selscrollupdate(.{ .mode = sel_empty + 1, .selection_type = sel_regular, .alt = 0, .snap = 0, .ob_x = 0, .ob_y = 2, .oe_x = 3, .oe_y = 3, .nb_x = 0, .nb_y = 2, .ne_x = 3, .ne_y = 3 }, 1, 0, 9, 2);

    try std.testing.expectEqual(@as(c_int, 1), plan.effect.dirty);
    try std.testing.expectEqual(@as(c_int, 4), plan.update.ob_y);
    try std.testing.expectEqual(@as(c_int, 5), plan.update.oe_y);
}

test "regular selection matches inclusive endpoints" {
    try std.testing.expectEqual(@as(c_int, 1), st_selected(3, 2, 2, 0, 0, 0, 1, 1, 2, 5, 2));
    try std.testing.expectEqual(@as(c_int, 0), st_selected(6, 2, 2, 0, 0, 0, 1, 1, 2, 5, 2));
}

test "selection extend plan marks dirty and final mode" {
    const plan = st_selextendupdate(.{ .mode = sel_empty, .selection_type = sel_regular, .alt = 0, .snap = 0, .ob_x = 1, .ob_y = 2, .oe_x = 1, .oe_y = 2, .nb_x = 1, .nb_y = 2, .ne_x = 3, .ne_y = 4 }, 3, 5, sel_rectangular, 0);

    try std.testing.expectEqual(@as(c_int, 1), plan.effect.dirty);
    try std.testing.expectEqual(@as(c_int, 2), plan.effect.top);
    try std.testing.expectEqual(@as(c_int, 5), plan.effect.bot);
    try std.testing.expectEqual(@as(c_int, sel_empty + 1), plan.update.mode);
}

test "selection clear plan skips inactive selection" {
    try std.testing.expectEqual(@as(c_int, 0), st_selclearplan(-1));
    try std.testing.expectEqual(@as(c_int, 1), st_selclearplan(0));
}

test "selection start plan initializes regular selection" {
    const plan = st_selstartupdate(.{ .mode = 0, .selection_type = sel_regular, .alt = 0, .snap = 0, .ob_x = -1, .ob_y = 0, .oe_x = -1, .oe_y = 0, .nb_x = 0, .nb_y = 0, .ne_x = 0, .ne_y = 0 }, 3, 4, 1, 1);

    try std.testing.expectEqual(@as(c_int, sel_empty), plan.update.mode);
    try std.testing.expectEqual(@as(c_int, sel_regular), plan.update.selection_type);
    try std.testing.expectEqual(@as(c_int, 1), plan.update.alt);
    try std.testing.expectEqual(@as(c_int, 1), plan.effect.dirty);
}

test "selection line snap x chooses edge by direction" {
    try std.testing.expectEqual(@as(c_int, 0), st_selsnaplinex(-1, 10));
    try std.testing.expectEqual(@as(c_int, 9), st_selsnaplinex(1, 10));
    try std.testing.expectEqual(@as(c_int, sel_snap_line_move), st_selsnaplinestep(3, -1, 5, 1).action);
    try std.testing.expectEqual(@as(c_int, 2), st_selsnaplinestep(3, -1, 5, 1).y);
    try std.testing.expectEqual(@as(c_int, sel_snap_line_stop), st_selsnaplinestep(3, 1, 5, 0).action);
}

test "selection word snap break follows delimiter state" {
    const prev = selection.SnapPrev{ .delim = 0, .rune = 'a' };
    try std.testing.expect(selection.snapWordBreak(0, 1, prev, ','));
    try std.testing.expect(selection.snapWordBreak(0, 1, .{ .delim = 1, .rune = ',' }, '.'));
    try std.testing.expect(!selection.snapWordBreak(attr_wdummy, 1, prev, ','));
    try std.testing.expect(!selection.snapWordBreak(0, 0, prev, 'b'));
    try std.testing.expect(selection.snapWordPastLine(5, 5));
    try std.testing.expect(!selection.snapWordPastLine(4, 5));
}

test "selection word snap iterator adapter requests read and resolves accept" {
    const request = st_selsnapworditerrequest(2, 2, 1, 10, 5, 0, 'a');
    try std.testing.expectEqual(@as(c_int, 1), request.action);
    try std.testing.expectEqual(@as(c_int, 3), request.x);

    const step = st_selsnapworditerresolve(request, 0, 'a', .{
        .wrap_allowed = 1,
        .linelen = 6,
        .mode = 0,
        .delim = 0,
        .rune = 'b',
    });
    try std.testing.expectEqual(@as(c_int, sel_snap_word_accept), step.action);
    try std.testing.expectEqual(@as(c_int, 3), step.x);
    try std.testing.expectEqual(@as(u32, 'b'), step.prevrune);
}

test "search line plan skips dummy cells and returns next match" {
    const line = [_]ZigGlyph{
        .{ .u = '你', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = 0, .mode = attr_wdummy, .fg = 0, .bg = 0 },
        .{ .u = '好', .mode = 0, .fg = 0, .bg = 0 },
    };
    const query = [_]u32{ '你', '好' };
    const plan = st_searchlineplan(&line, 0, line.len, &query, query.len, 0, 4, 3, 2);
    const done = st_searchlineplan(&line, plan.next_x, line.len, &query, query.len, 1, 4, 3, 2);

    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.MatchAppendKind.append)), plan.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.match.x);
    try std.testing.expectEqual(@as(c_int, 3), plan.match.len);
    try std.testing.expectEqual(@as(c_int, 1), plan.next_x);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.MatchAppendKind.skip)), done.kind);
}

test "search current valid checks active and bounds" {
    try std.testing.expect(search.currentValid(true, 0, 1));
    try std.testing.expect(!search.currentValid(false, 0, 1));
    try std.testing.expect(!search.currentValid(true, 2, 1));
}

test "search match list checks all and current matches" {
    const matches = [_]ZigSearchMatch{
        .{ .x = 5, .y = 4, .scr = 2, .len = 3 },
        .{ .x = 1, .y = 0, .scr = 0, .len = 2 },
    };

    try std.testing.expectEqual(@as(c_int, 1), st_searchmatchlist(&matches, matches.len, 1, -1, 2, 7, 4));
    try std.testing.expectEqual(@as(c_int, 0), st_searchmatchlist(&matches, matches.len, 1, -1, 2, 9, 4));
    try std.testing.expectEqual(@as(c_int, 1), st_searchcurrentmatch(&matches, matches.len, 1, 1, 0, 2, 0));
    try std.testing.expectEqual(@as(c_int, 0), st_searchcurrentmatch(&matches, matches.len, 1, 9, 0, 2, 0));
    try std.testing.expectEqual(@as(c_int, 0), st_searchmatchlist(null, 0, 1, -1, 0, 0, 0));
}

test "search line plan grows match cap when full" {
    const line = [_]ZigGlyph{
        .{ .u = '中', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '文', .mode = 0, .fg = 0, .bg = 0 },
    };
    const query = [_]u32{'中'};
    const grow = st_searchlineplan(&line, 0, line.len, &query, query.len, 4, 4, 3, 2);

    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.MatchAppendKind.grow_append)), grow.kind);
    try std.testing.expectEqual(@as(c_int, 8), grow.cap);
    try std.testing.expectEqual(@as(c_int, 0), grow.match.x);
}

test "search next current preserves valid old current" {
    try std.testing.expectEqual(@as(c_int, -1), search.nextCurrent(2, 0));
    try std.testing.expectEqual(@as(c_int, 2), search.nextCurrent(2, 5));
    try std.testing.expectEqual(@as(c_int, 0), search.nextCurrent(8, 5));
}

test "search jump changes scroll only for valid different target" {
    try std.testing.expectEqual(@as(c_int, 3), search.jumpScroll(true, 0, 3));
    try std.testing.expectEqual(@as(c_int, 0), search.jumpScroll(false, 0, 3));
}

test "search history index wraps around current history head" {
    try std.testing.expectEqual(@as(c_int, 6), search.historyIndex(7, 2, 10));
    try std.testing.expectEqual(@as(c_int, 9), search.historyIndex(0, 2, 10));
    try std.testing.expectEqual(@as(c_int, 4), search.visibleHistoryIndex(3, 7, 7, 10));
    try std.testing.expectEqual(@as(c_int, 9), search.visibleHistoryIndex(0, 0, 2, 10));
}

test "history line plan maps scrollback and live rows" {
    const hist_line = st_tlinehistplan(5, 10, 7);
    const live_line = st_tlinehistplan(6, 10, 7);

    try std.testing.expectEqual(@as(c_int, 1), hist_line.hist);
    try std.testing.expectEqual(@as(c_int, 5), hist_line.index);
    try std.testing.expectEqual(@as(c_int, 0), live_line.hist);
    try std.testing.expectEqual(@as(c_int, 0), live_line.index);
}

test "search step wraps in both directions" {
    try std.testing.expectEqual(@as(c_int, 0), st_searchstep(1, 3, 2, 1).current);
    try std.testing.expectEqual(@as(c_int, 2), st_searchstep(1, 3, 0, -1).current);
    try std.testing.expectEqual(@as(c_int, 0), st_searchstep(0, 3, 1, 1).run);
}

test "search char movement skips utf8 continuation bytes" {
    const input = "a你b";

    try std.testing.expectEqual(@as(usize, 1), search.prevChar(input, 4));
    try std.testing.expectEqual(@as(usize, 4), search.nextChar(input, 1));
}

test "search cursor edit adapters expose tagged actions" {
    const input = "abc  你好";
    const snapshot = ZigSearchSnapshot{ .query_len = 0, .inputmode = 1, .inputlen = input.len, .inputcursor = input.len, .inputcap = 32, .nmatches = 0, .match_cap = 0, .current = -1, .active = 0 };
    const backspace = st_searchcursorupdate(snapshot, input, @intFromEnum(search.CursorAction.backspace));
    const move_left = st_searchcursorupdate(snapshot, input, @intFromEnum(search.CursorAction.move_left));
    const home_edit = st_searchcursorupdate(snapshot, input, @intFromEnum(search.CursorAction.home));
    const end_edit = st_searchcursorupdate(.{ .query_len = 0, .inputmode = 1, .inputlen = input.len, .inputcursor = 0, .inputcap = 32, .nmatches = 0, .match_cap = 0, .current = -1, .active = 0 }, input, @intFromEnum(search.CursorAction.end));
    const inactive = st_searchcursorupdate(.{ .query_len = 0, .inputmode = 0, .inputlen = input.len, .inputcursor = input.len, .inputcap = 32, .nmatches = 0, .match_cap = 0, .current = -1, .active = 0 }, input, @intFromEnum(search.CursorAction.backspace));

    try std.testing.expectEqual(@as(usize, 8), backspace.delete_start);
    try std.testing.expectEqual(@as(usize, input.len), backspace.delete_end);
    try std.testing.expectEqual(@as(usize, 8), backspace.update.inputcursor);
    try std.testing.expectEqual(@as(c_int, 1), backspace.effect.refresh_search);
    try std.testing.expectEqual(@as(usize, 8), move_left.update.inputcursor);
    try std.testing.expectEqual(@as(c_int, 1), move_left.effect.redraw);
    try std.testing.expectEqual(@as(usize, 0), home_edit.update.inputcursor);
    try std.testing.expectEqual(@as(usize, input.len), end_edit.update.inputcursor);
    try std.testing.expectEqual(@as(c_int, 0), inactive.effect.refresh_search);
}

test "search state edit adapters expose tagged actions" {
    const clear = st_searchstateupdate(.{ .query_len = 2, .inputmode = 1, .inputlen = 4, .inputcursor = 4, .inputcap = 8, .nmatches = 1, .match_cap = 2, .current = 0, .active = 1 }, @intFromEnum(search.StateAction.clear_input));
    const inactive_clear = st_searchstateupdate(.{ .query_len = 2, .inputmode = 0, .inputlen = 4, .inputcursor = 4, .inputcap = 8, .nmatches = 1, .match_cap = 2, .current = 0, .active = 1 }, @intFromEnum(search.StateAction.clear_input));
    const commit_clear = st_searchstateupdate(.{ .query_len = 2, .inputmode = 1, .inputlen = 0, .inputcursor = 0, .inputcap = 8, .nmatches = 1, .match_cap = 2, .current = 0, .active = 1 }, @intFromEnum(search.StateAction.commit));
    const commit_set = st_searchstateupdate(.{ .query_len = 2, .inputmode = 1, .inputlen = 3, .inputcursor = 3, .inputcap = 8, .nmatches = 1, .match_cap = 2, .current = 0, .active = 1 }, @intFromEnum(search.StateAction.commit));
    const cancel = st_searchstateupdate(.{ .query_len = 2, .inputmode = 1, .inputlen = 3, .inputcursor = 3, .inputcap = 8, .nmatches = 1, .match_cap = 2, .current = 0, .active = 1 }, @intFromEnum(search.StateAction.cancel));

    try std.testing.expectEqual(@as(usize, 0), clear.update.inputlen);
    try std.testing.expectEqual(@as(usize, 0), clear.update.inputcursor);
    try std.testing.expectEqual(@as(c_int, 1), clear.effect.refresh_search);
    try std.testing.expectEqual(@as(c_int, 0), inactive_clear.effect.refresh_search);
    try std.testing.expectEqual(@as(c_int, 1), commit_clear.effect.clear_query);
    try std.testing.expectEqual(@as(c_int, 1), commit_set.effect.refresh_search);
    try std.testing.expectEqual(@as(c_int, 1), cancel.effect.redraw);
}

test "search input edit plans guard inactive and empty cases" {
    try std.testing.expectEqual(@as(usize, 0), st_searchcursorupdate(.{ .query_len = 0, .inputmode = 1, .inputlen = 3, .inputcursor = 0, .inputcap = 8, .nmatches = 0, .match_cap = 0, .current = -1, .active = 0 }, "abc", @intFromEnum(search.CursorAction.backspace)).delete_end);
    try std.testing.expectEqual(@as(usize, 1), st_searchcursorupdate(.{ .query_len = 0, .inputmode = 1, .inputlen = 3, .inputcursor = 2, .inputcap = 8, .nmatches = 0, .match_cap = 0, .current = -1, .active = 0 }, "abc", @intFromEnum(search.CursorAction.backspace)).delete_start);
    try std.testing.expectEqual(@as(usize, 0), st_searchcursorupdate(.{ .query_len = 0, .inputmode = 1, .inputlen = 3, .inputcursor = 3, .inputcap = 8, .nmatches = 0, .match_cap = 0, .current = -1, .active = 0 }, "abc", @intFromEnum(search.CursorAction.delete_forward)).delete_end);
    try std.testing.expectEqual(@as(usize, 2), st_searchcursorupdate(.{ .query_len = 0, .inputmode = 1, .inputlen = 3, .inputcursor = 2, .inputcap = 8, .nmatches = 0, .match_cap = 0, .current = -1, .active = 0 }, "abc", @intFromEnum(search.CursorAction.delete_forward)).delete_start);
    try std.testing.expectEqual(@as(usize, 0), st_searchcursorupdate(.{ .query_len = 0, .inputmode = 1, .inputlen = 3, .inputcursor = 0, .inputcap = 8, .nmatches = 0, .match_cap = 0, .current = -1, .active = 0 }, "abc", @intFromEnum(search.CursorAction.delete_word)).delete_end);
}

test "search delete plan validates range and updates length" {
    try std.testing.expectEqual(@as(c_int, 1), st_searchdeleteplan(2, 5, 9).run);
    try std.testing.expectEqual(@as(usize, 6), st_searchdeleteplan(2, 5, 9).new_len);
    try std.testing.expectEqual(@as(c_int, 0), st_searchdeleteplan(5, 2, 9).run);
}

test "search commit and cancel plans report actions" {
    try std.testing.expectEqual(@as(c_int, 0), st_searchstateupdate(.{ .query_len = 1, .inputmode = 0, .inputlen = 1, .inputcursor = 1, .inputcap = 8, .nmatches = 0, .match_cap = 0, .current = -1, .active = 0 }, @intFromEnum(search.StateAction.commit)).effect.refresh_search);
    try std.testing.expectEqual(@as(c_int, 1), st_searchstateupdate(.{ .query_len = 1, .inputmode = 1, .inputlen = 0, .inputcursor = 0, .inputcap = 8, .nmatches = 0, .match_cap = 0, .current = -1, .active = 1 }, @intFromEnum(search.StateAction.commit)).effect.clear_query);
    try std.testing.expectEqual(@as(c_int, 1), st_searchstateupdate(.{ .query_len = 1, .inputmode = 1, .inputlen = 3, .inputcursor = 3, .inputcap = 8, .nmatches = 0, .match_cap = 0, .current = -1, .active = 1 }, @intFromEnum(search.StateAction.commit)).effect.refresh_search);
    try std.testing.expectEqual(@as(c_int, 1), st_searchstateupdate(.{ .query_len = 1, .inputmode = 1, .inputlen = 3, .inputcursor = 3, .inputcap = 8, .nmatches = 0, .match_cap = 0, .current = -1, .active = 1 }, @intFromEnum(search.StateAction.cancel)).effect.redraw);
    try std.testing.expectEqual(@as(c_int, 1), st_searchstateupdate(.{ .query_len = 1, .inputmode = 1, .inputlen = 3, .inputcursor = 3, .inputcap = 8, .nmatches = 0, .match_cap = 0, .current = -1, .active = 1 }, @intFromEnum(search.StateAction.clear_input)).effect.refresh_search);
    try std.testing.expectEqual(@as(c_int, 0), st_searchstateupdate(.{ .query_len = 1, .inputmode = 0, .inputlen = 3, .inputcursor = 3, .inputcap = 8, .nmatches = 0, .match_cap = 0, .current = -1, .active = 1 }, @intFromEnum(search.StateAction.clear_input)).effect.refresh_search);
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

test "search prompt update resets input and requests redraw" {
    const result = st_searchpromptupdate(.{
        .query_len = 0,
        .inputmode = 0,
        .inputlen = 5,
        .inputcursor = 3,
        .inputcap = 0,
        .nmatches = 2,
        .match_cap = 4,
        .current = 1,
        .active = 1,
    });

    try std.testing.expectEqual(@as(c_int, 1), result.update.inputmode);
    try std.testing.expectEqual(@as(usize, 0), result.update.inputlen);
    try std.testing.expectEqual(@as(usize, 0), result.update.inputcursor);
    try std.testing.expectEqual(@as(usize, 64), result.update.inputcap);
    try std.testing.expectEqual(@as(c_int, 1), result.effect.alloc_input);
    try std.testing.expectEqual(@as(c_int, 1), result.effect.redraw);
}

test "search input update describes buffer edit and refresh" {
    const result = st_searchinputupdate(.{
        .query_len = 0,
        .inputmode = 1,
        .inputlen = 3,
        .inputcursor = 1,
        .inputcap = 8,
        .nmatches = 2,
        .match_cap = 4,
        .current = 0,
        .active = 1,
    }, 2);

    try std.testing.expectEqual(@as(c_int, 1), result.effect.refresh_search);
    try std.testing.expectEqual(@as(usize, 1), result.insert_at);
    try std.testing.expectEqual(@as(usize, 3), result.move_dst);
    try std.testing.expectEqual(@as(usize, 1), result.move_src);
    try std.testing.expectEqual(@as(usize, 3), result.move_len);
    try std.testing.expectEqual(@as(usize, 5), result.update.inputlen);
    try std.testing.expectEqual(@as(usize, 3), result.update.inputcursor);
}

test "search set update requests query alloc and refresh" {
    const result = st_searchsetupdate(.{
        .query_len = 1,
        .inputmode = 1,
        .inputlen = 3,
        .inputcursor = 2,
        .inputcap = 8,
        .nmatches = 2,
        .match_cap = 4,
        .current = 1,
        .active = 0,
    }, 6, 2);

    try std.testing.expectEqual(@as(usize, 6), result.alloc_len);
    try std.testing.expectEqual(@as(c_int, 2), result.update.query_len);
    try std.testing.expectEqual(@as(c_int, 1), result.update.active);
    try std.testing.expectEqual(@as(c_int, -1), result.update.current);
    try std.testing.expectEqual(@as(c_int, 1), result.effect.alloc_query);
    try std.testing.expectEqual(@as(c_int, 1), result.effect.clear_query);
    try std.testing.expectEqual(@as(c_int, 1), result.effect.refresh_search);
    try std.testing.expectEqual(@as(c_int, 1), result.effect.jump);
    try std.testing.expectEqual(@as(c_int, 1), result.effect.redraw);
}

test "get selection exec plan handles regular multiline" {
    const line = [_]ZigGlyph{
        .{ .u = '甲', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '乙', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '丙', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
    };
    const first = st_getselexecplan(sel_regular, 3, 2, 5, 4, 2, line.len, &line, 4);
    const middle = st_getselexecplan(sel_regular, 3, 2, 5, 4, 3, line.len, &line, 4);

    try std.testing.expectEqual(@as(c_int, 3), first.start_x);
    try std.testing.expectEqual(@as(c_int, 4), first.last_index);
    try std.testing.expectEqual(@as(c_int, 1), first.newline);
    try std.testing.expectEqual(@as(c_int, 0), middle.start_x);
    try std.testing.expectEqual(@as(c_int, 4), middle.last_index);
}

test "get selection exec plan keeps rectangular bounds" {
    const line = [_]ZigGlyph{
        .{ .u = '甲', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '乙', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '丙', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '丁', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '戊', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '己', .mode = 0, .fg = 0, .bg = 0 },
    };
    const plan = st_getselexecplan(sel_rectangular, 3, 2, 5, 4, 3, line.len, &line, 4);

    try std.testing.expectEqual(@as(c_int, 3), plan.start_x);
    try std.testing.expectEqual(@as(c_int, 5), plan.last_index);
}

test "get selection exec plan reports buffer size empty line and wrap newline" {
    const empty = [_]ZigGlyph{
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 },
    };
    const wrapped = [_]ZigGlyph{
        .{ .u = '甲', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '乙', .mode = attr_wrap, .fg = 0, .bg = 0 },
    };
    const empty_plan = st_getselexecplan(sel_regular, 0, 2, 0, 3, 2, empty.len, &empty, 4);
    const wrapped_regular = st_getselexecplan(sel_regular, 0, 0, 1, 1, 0, wrapped.len, &wrapped, 4);
    const wrapped_rect = st_getselexecplan(sel_rectangular, 0, 0, 1, 1, 0, wrapped.len, &wrapped, 4);

    try std.testing.expectEqual(@as(c_int, 88), empty_plan.bufsize);
    try std.testing.expectEqual(@as(c_int, 1), empty_plan.empty);
    try std.testing.expectEqual(@as(c_int, 0), wrapped_regular.newline);
    try std.testing.expectEqual(@as(c_int, 1), wrapped_rect.newline);
}

test "rectangular selection checks both axes" {
    try std.testing.expectEqual(@as(c_int, 1), st_selected(4, 3, 2, 0, 0, 0, sel_rectangular, 2, 1, 5, 4));
    try std.testing.expectEqual(@as(c_int, 0), st_selected(6, 3, 2, 0, 0, 0, sel_rectangular, 2, 1, 5, 4));
}

test "selection rejects inactive or alternate screen mismatch" {
    try std.testing.expectEqual(@as(c_int, 0), st_selected(1, 1, sel_empty, 0, 0, 0, 1, 0, 0, 2, 2));
    try std.testing.expectEqual(@as(c_int, 0), st_selected(1, 1, 2, 0, 1, 0, 1, 0, 0, 2, 2));
}
