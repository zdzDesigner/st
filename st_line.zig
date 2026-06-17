//! st_line.zig 承载剩余 C 侧无副作用的行/选择区/列位置判断逻辑。
//! [输入]: C 侧传入只读 glyph 行、终端列数、tab stops，以及 selection 的值拷贝字段。
//! [输出]: 行有效长度、dump 输出范围、tab 跳转目标列，或指定坐标是否落在当前 selection 内。
//! [副作用边界]: 不访问全局 `term` / `sel`，不修改 glyph、dirty、selection，也不做 IO/分配/X11 调用。
//! [定位]: 替代 `tlinelen(...)`、`tlinehistlen(...)`、`tputtab(...)` 的扫描主体、`selected(...)` 的纯判断主体，以及 `selnormalize(...)` 的 bounds 计算主体。

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

const ZigSelScrollPlan = extern struct {
    action: c_int,
    ob_y: c_int,
    oe_y: c_int,
};

const ZigSelExtendPlan = extern struct {
    dirty: c_int,
    top: c_int,
    bot: c_int,
    mode: c_int,
};

const ZigSelStartPlan = extern struct {
    mode: c_int,
    sel_type: c_int,
    alt: c_int,
    snap: c_int,
    x: c_int,
    y: c_int,
    final_mode: c_int,
};

const ZigSelSnapWordPlan = extern struct {
    x: c_int,
    y: c_int,
    wrap_x: c_int,
    wrap_y: c_int,
    wrapped: c_int,
    in_bounds: c_int,
};

const ZigSelSnapWordStep = extern struct {
    action: c_int,
    x: c_int,
    y: c_int,
    prevdelim: c_int,
    prevrune: u32,
};

const ZigGetSelLinePlan = extern struct {
    start_x: c_int,
    last_x: c_int,
};

const ZigSearchStepPlan = extern struct {
    run: c_int,
    current: c_int,
};

const ZigSearchDeletePlan = extern struct {
    run: c_int,
    new_len: usize,
};

const ZigSearchSetPlan = extern struct {
    alloc_len: usize,
    active: c_int,
    current: c_int,
};

const ZigSearchPromptPlan = extern struct {
    inputmode: c_int,
    inputlen: usize,
    inputcursor: usize,
    alloc: c_int,
    inputcap: usize,
};

const ZigExternalPipeLinePlan = extern struct {
    kind: c_int,
    lastpos: c_int,
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
const search_action_none = @intFromEnum(search.Action.none);
const search_action_clear = @intFromEnum(search.Action.clear);
const search_action_set = @intFromEnum(search.Action.set);
const search_action_redraw = @intFromEnum(search.Action.redraw);
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

export fn st_selscrollplan(ob_x: c_int, ob_y: c_int, oe_y: c_int, nb_y: c_int, ne_y: c_int, orig: c_int, top: c_int, bot: c_int, n: c_int) ZigSelScrollPlan {
    const plan = selection.scrollPlan(ob_x, ob_y, oe_y, .{ .start = .{ .x = 0, .y = nb_y }, .end = .{ .x = 0, .y = ne_y } }, orig, top, bot, n);
    return .{ .action = @intFromEnum(plan.action), .ob_y = plan.origin_y, .oe_y = plan.extent_y };
}

export fn st_selextendplan(old_oe_x: c_int, old_oe_y: c_int, old_type: c_int, old_nb_y: c_int, old_ne_y: c_int, new_oe_x: c_int, new_oe_y: c_int, new_type: c_int, new_nb_y: c_int, new_ne_y: c_int, old_mode: c_int, done: c_int) ZigSelExtendPlan {
    const old_selection_type = selectionType(old_type);
    const new_selection_type = selectionType(new_type);
    const mode = selectionMode(old_mode);
    const plan = selection.extendPlan(
        .{ .x = old_oe_x, .y = old_oe_y },
        old_selection_type,
        .{ .start = .{ .x = 0, .y = old_nb_y }, .end = .{ .x = 0, .y = old_ne_y } },
        .{ .x = new_oe_x, .y = new_oe_y },
        new_selection_type,
        .{ .start = .{ .x = 0, .y = new_nb_y }, .end = .{ .x = 0, .y = new_ne_y } },
        mode,
        done != 0,
    );
    return .{
        .dirty = boolInt(plan.dirty),
        .top = plan.top,
        .bot = plan.bot,
        .mode = @intFromEnum(plan.mode),
    };
}

export fn st_selclearplan(ob_x: c_int) c_int {
    return boolInt(selection.shouldClear(ob_x));
}

export fn st_selstartplan(col: c_int, row: c_int, snap: c_int, alt_screen: c_int) ZigSelStartPlan {
    const plan = selection.startPlan(.{ .x = col, .y = row }, snap, alt_screen != 0);
    return .{
        .mode = @intFromEnum(plan.mode),
        .sel_type = @intFromEnum(plan.selection_type),
        .alt = boolInt(plan.alt),
        .snap = plan.snap,
        .x = plan.point.x,
        .y = plan.point.y,
        .final_mode = @intFromEnum(plan.final_mode),
    };
}

export fn st_selsnaplinex(direction: c_int, col: c_int) c_int {
    return selection.snapLineX(direction, col);
}

export fn st_selsnapwordplan(x: c_int, y: c_int, direction: c_int, col: c_int, row: c_int) ZigSelSnapWordPlan {
    const plan = selection.snapWordPlan(.{ .x = x, .y = y }, direction, .{ .cols = col, .rows = row });
    return .{
        .x = plan.point.x,
        .y = plan.point.y,
        .wrap_x = plan.wrap_point.x,
        .wrap_y = plan.wrap_point.y,
        .wrapped = boolInt(plan.wrapped),
        .in_bounds = boolInt(plan.in_bounds),
    };
}

export fn st_selsnapwordbreak(mode: c_ushort, delim: c_int, prevdelim: c_int, rune: u32, prevrune: u32) c_int {
    const prev = selection.SnapPrev{ .delim = prevdelim, .rune = prevrune };
    return boolInt(selection.snapWordBreak(mode, delim, prev, rune));
}

export fn st_selsnapwordpastline(x: c_int, linelen: c_int) c_int {
    return boolInt(selection.snapWordPastLine(x, linelen));
}

export fn st_selsnapwordstep(x: c_int, y: c_int, linelen: c_int, mode: c_ushort, delim: c_int, prevdelim: c_int, rune: u32, prevrune: u32) ZigSelSnapWordStep {
    const step = selection.snapWordStep(.{ .x = x, .y = y }, linelen, mode, delim, .{ .delim = prevdelim, .rune = prevrune }, rune);
    switch (step) {
        .stop => |prev| return .{ .action = sel_snap_word_break, .x = x, .y = y, .prevdelim = prev.delim, .prevrune = prev.rune },
        .accept => |accepted| return .{ .action = sel_snap_word_accept, .x = accepted.point.x, .y = accepted.point.y, .prevdelim = accepted.prev.delim, .prevrune = accepted.prev.rune },
    }
}

export fn st_selected(x: c_int, y: c_int, mode: c_int, ob_x: c_int, sel_alt: c_int, alt_screen: c_int, sel_type: c_int, nb_x: c_int, nb_y: c_int, ne_x: c_int, ne_y: c_int) c_int {
    const selection_type = selectionType(sel_type);
    const bounds = selection.Bounds{ .start = .{ .x = nb_x, .y = nb_y }, .end = .{ .x = ne_x, .y = ne_y } };
    const active = mode != sel_empty and ob_x != -1;
    return boolInt(selection.isSelected(.{ .x = x, .y = y }, active, sel_alt == alt_screen, selection_type, bounds));
}

export fn st_searchcurrentvalid(active: c_int, current: c_int, nmatches: c_int) c_int {
    return boolInt(search.currentValid(active != 0, current, nmatches));
}

export fn st_searchhit(active: c_int, match_scr: c_int, term_scr: c_int, match_y: c_int, y: c_int, x: c_int, match_x: c_int, match_len: c_int) c_int {
    return boolInt(search.hit(active != 0, match_scr, term_scr, match_y, y, x, match_x, match_len));
}

export fn st_searchlinematch(line: [*]const ZigGlyph, x: c_int, linelen: c_int, query: [*]const u32, qlen: c_int, col: c_int) c_int {
    return search.lineMatch(ZigGlyph, line[0..@intCast(col)], x, linelen, query[0..@intCast(qlen)], col);
}

export fn st_searchnextcurrent(oldcurrent: c_int, nmatches: c_int) c_int {
    return search.nextCurrent(oldcurrent, nmatches);
}

export fn st_searchjumpscr(current_valid: c_int, term_scr: c_int, match_scr: c_int) c_int {
    return search.jumpScroll(current_valid != 0, term_scr, match_scr);
}

export fn st_searchstep(active: c_int, nmatches: c_int, current: c_int, direction: c_int) ZigSearchStepPlan {
    const plan = search.step(active != 0, nmatches, current, direction);
    return .{
        .run = boolInt(plan.run),
        .current = plan.current,
    };
}

export fn st_searchprevchar(input: [*]const u8, cursor: usize) usize {
    return search.prevChar(input[0..cursor], cursor);
}

export fn st_searchnextchar(input: [*]const u8, cursor: usize, inputlen: usize) usize {
    return search.nextChar(input[0..inputlen], cursor);
}

export fn st_searchdeletewordstart(input: [*]const u8, cursor: usize) usize {
    return search.deleteWordStart(input[0..cursor], cursor);
}

export fn st_searchinputcap(inputlen: usize, add_len: usize, inputcap: usize) usize {
    return search.inputCap(inputlen, add_len, inputcap);
}

export fn st_searchinputgrow(inputlen: usize, add_len: usize, inputcap: usize) c_int {
    return boolInt(search.inputGrow(inputlen, add_len, inputcap));
}

export fn st_searchinputplan(inputmode: c_int, len: usize) c_int {
    return boolInt(search.inputPlan(inputmode != 0, len));
}

export fn st_searchbackspaceplan(inputmode: c_int, inputlen: usize, cursor: usize) c_int {
    return boolInt(search.backspacePlan(inputmode != 0, inputlen, cursor));
}

export fn st_searchdeleteforwardplan(inputmode: c_int, cursor: usize, inputlen: usize) c_int {
    return boolInt(search.deleteForwardPlan(inputmode != 0, cursor, inputlen));
}

export fn st_searchdeletewordplan(inputmode: c_int, cursor: usize) c_int {
    return boolInt(search.deleteWordPlan(inputmode != 0, cursor));
}

export fn st_searchcursorplan(inputmode: c_int) c_int {
    return boolInt(search.cursorPlan(inputmode != 0));
}

export fn st_searchscanplan(active: c_int, qlen: c_int) c_int {
    return boolInt(search.scanPlan(active != 0, qlen));
}

export fn st_searchdeleteplan(start: usize, end: usize, inputlen: usize) ZigSearchDeletePlan {
    const plan = search.deletePlan(start, end, inputlen);
    return .{ .run = boolInt(plan.run), .new_len = plan.new_len };
}

export fn st_searchcommitplan(inputmode: c_int, inputlen: usize) c_int {
    return @intFromEnum(search.commitPlan(inputmode != 0, inputlen));
}

export fn st_searchcancelplan(inputmode: c_int) c_int {
    return @intFromEnum(search.cancelPlan(inputmode != 0));
}

export fn st_searchclearinputplan(inputmode: c_int) c_int {
    return boolInt(search.clearInputPlan(inputmode != 0));
}

export fn st_searchbaractive(inputmode: c_int, active: c_int) c_int {
    return boolInt(search.barActive(inputmode != 0, active != 0));
}

export fn st_externalpipelinelen(linelen: c_int, col: c_int) ZigExternalPipeLinePlan {
    const plan = (line_core.VisualLine{ .len = linelen, .cols = col }).externalPipe();
    return .{ .kind = @intFromEnum(plan.kind), .lastpos = plan.lastpos };
}

export fn st_externalpipewrap(mode: c_ushort) c_int {
    return boolInt(line_core.externalPipeWrap(mode));
}

export fn st_searchpromptplan(has_input: c_int, inputcap: usize) ZigSearchPromptPlan {
    const plan = search.promptPlan(has_input != 0, inputcap);
    return .{
        .inputmode = boolInt(plan.inputmode),
        .inputlen = plan.inputlen,
        .inputcursor = plan.inputcursor,
        .alloc = boolInt(plan.alloc),
        .inputcap = plan.inputcap,
    };
}

export fn st_searchsetplan(query_len: usize, qlen: c_int) ZigSearchSetPlan {
    const plan = search.setPlan(query_len, qlen);
    return .{
        .alloc_len = plan.alloc_len,
        .active = boolInt(plan.active),
        .current = plan.current,
    };
}

export fn st_searchmatchcap(nmatches: c_int, cap: c_int) c_int {
    return search.matchCap(nmatches, cap);
}

export fn st_getsellineplan(sel_type: c_int, nb_x: c_int, nb_y: c_int, ne_x: c_int, ne_y: c_int, y: c_int, col: c_int) ZigGetSelLinePlan {
    const selection_type = selectionType(sel_type);
    const plan = selection.getLinePlan(selection_type, .{ .start = .{ .x = nb_x, .y = nb_y }, .end = .{ .x = ne_x, .y = ne_y } }, y, col);
    return .{
        .start_x = plan.start_x,
        .last_x = plan.last_x,
    };
}

export fn st_getselbufsize(col: c_int, nb_y: c_int, ne_y: c_int, utf_siz: c_int) c_int {
    return selection.getBufferSize(col, .{ .start = .{ .x = 0, .y = nb_y }, .end = .{ .x = 0, .y = ne_y } }, utf_siz);
}

export fn st_getsellastx(last_x: c_int, linelen: c_int) c_int {
    return selection.getLastX(last_x, linelen);
}

export fn st_getselnewline(y: c_int, ne_y: c_int, last_x: c_int, linelen: c_int, last_mode: c_ushort, sel_type: c_int) c_int {
    const selection_type = selectionType(sel_type);
    return boolInt(selection.needsNewline(y, .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 0, .y = ne_y } }, last_x, linelen, last_mode, selection_type));
}

export fn st_planselnormalize(sel_type: c_int, ob_x: c_int, ob_y: c_int, oe_x: c_int, oe_y: c_int) ZigSelBounds {
    const selection_type = selectionType(sel_type);
    const bounds = selection.normalize(selection_type, .{ .x = ob_x, .y = ob_y }, .{ .x = oe_x, .y = oe_y });
    return .{ .nb_x = bounds.start.x, .nb_y = bounds.start.y, .ne_x = bounds.end.x, .ne_y = bounds.end.y };
}

export fn st_planselnormalizecols(sel_type: c_int, nb_x: c_int, ne_x: c_int, nb_len: c_int, ne_len: c_int, col: c_int) ZigSelBounds {
    const selection_type = selectionType(sel_type);
    const bounds = selection.normalizeColumns(selection_type, .{ .start = .{ .x = nb_x, .y = 0 }, .end = .{ .x = ne_x, .y = 0 } }, nb_len, ne_len, col);
    return .{ .nb_x = bounds.start.x, .nb_y = 0, .ne_x = bounds.end.x, .ne_y = 0 };
}

fn attrMask(attr: c_int) c_ushort {
    return @truncate(@as(c_uint, @bitCast(attr)));
}

fn boolInt(value: bool) c_int {
    return if (value) 1 else 0;
}

fn selectionType(value: c_int) selection.SelectionType {
    return if (value == sel_rectangular) .rectangular else .regular;
}

fn selectionMode(value: c_int) selection.SelectionMode {
    if (value == sel_empty) return .empty;
    if (value == 0) return .idle;
    return .ready;
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
    const plan = st_selscrollplan(0, 2, 6, 2, 6, 4, 0, 9, 1);

    try std.testing.expectEqual(@as(c_int, sel_scroll_clear), plan.action);
}

test "selection scroll moves and normalizes selection inside region" {
    const plan = st_selscrollplan(0, 2, 3, 2, 3, 1, 0, 9, 2);

    try std.testing.expectEqual(@as(c_int, sel_scroll_normalize), plan.action);
    try std.testing.expectEqual(@as(c_int, 4), plan.ob_y);
    try std.testing.expectEqual(@as(c_int, 5), plan.oe_y);
}

test "regular selection matches inclusive endpoints" {
    try std.testing.expectEqual(@as(c_int, 1), st_selected(3, 2, 2, 0, 0, 0, 1, 1, 2, 5, 2));
    try std.testing.expectEqual(@as(c_int, 0), st_selected(6, 2, 2, 0, 0, 0, 1, 1, 2, 5, 2));
}

test "selection extend plan marks dirty and final mode" {
    const plan = st_selextendplan(1, 2, sel_regular, 2, 4, 3, 5, sel_rectangular, 1, 6, sel_empty, 0);

    try std.testing.expectEqual(@as(c_int, 1), plan.dirty);
    try std.testing.expectEqual(@as(c_int, 1), plan.top);
    try std.testing.expectEqual(@as(c_int, 6), plan.bot);
    try std.testing.expectEqual(@as(c_int, sel_empty + 1), plan.mode);
}

test "selection clear plan skips inactive selection" {
    try std.testing.expectEqual(@as(c_int, 0), st_selclearplan(-1));
    try std.testing.expectEqual(@as(c_int, 1), st_selclearplan(0));
}

test "selection start plan initializes regular selection" {
    const plan = st_selstartplan(3, 4, 1, 1);

    try std.testing.expectEqual(@as(c_int, sel_empty), plan.mode);
    try std.testing.expectEqual(@as(c_int, sel_regular), plan.sel_type);
    try std.testing.expectEqual(@as(c_int, 1), plan.alt);
    try std.testing.expectEqual(@as(c_int, sel_empty + 1), plan.final_mode);
}

test "selection line snap x chooses edge by direction" {
    try std.testing.expectEqual(@as(c_int, 0), st_selsnaplinex(-1, 10));
    try std.testing.expectEqual(@as(c_int, 9), st_selsnaplinex(1, 10));
}

test "selection word snap plans wrapped coordinates" {
    const forward = st_selsnapwordplan(9, 2, 1, 10, 5);
    try std.testing.expectEqual(@as(c_int, 0), forward.x);
    try std.testing.expectEqual(@as(c_int, 3), forward.y);
    try std.testing.expectEqual(@as(c_int, 9), forward.wrap_x);
    try std.testing.expectEqual(@as(c_int, 2), forward.wrap_y);
    try std.testing.expectEqual(@as(c_int, 1), forward.wrapped);
    try std.testing.expectEqual(@as(c_int, 1), forward.in_bounds);

    const backward = st_selsnapwordplan(0, 2, -1, 10, 5);
    try std.testing.expectEqual(@as(c_int, 9), backward.x);
    try std.testing.expectEqual(@as(c_int, 1), backward.y);
    try std.testing.expectEqual(@as(c_int, 9), backward.wrap_x);
    try std.testing.expectEqual(@as(c_int, 1), backward.wrap_y);
    try std.testing.expectEqual(@as(c_int, 1), backward.wrapped);
}

test "selection word snap reports row overflow" {
    const plan = st_selsnapwordplan(0, 0, -1, 10, 5);
    try std.testing.expectEqual(@as(c_int, 0), plan.in_bounds);
}

test "selection word snap break follows delimiter state" {
    try std.testing.expectEqual(@as(c_int, 1), st_selsnapwordbreak(0, 1, 0, ',', 'a'));
    try std.testing.expectEqual(@as(c_int, 1), st_selsnapwordbreak(0, 1, 1, '.', ','));
    try std.testing.expectEqual(@as(c_int, 0), st_selsnapwordbreak(attr_wdummy, 1, 0, ',', 'a'));
    try std.testing.expectEqual(@as(c_int, 0), st_selsnapwordbreak(0, 0, 0, 'b', 'a'));
    try std.testing.expectEqual(@as(c_int, 1), st_selsnapwordpastline(5, 5));
    try std.testing.expectEqual(@as(c_int, 0), st_selsnapwordpastline(4, 5));
}

test "selection word snap step accepts and updates previous glyph" {
    const step = st_selsnapwordstep(3, 2, 6, 0, 0, 0, 'b', 'a');
    try std.testing.expectEqual(@as(c_int, sel_snap_word_accept), step.action);
    try std.testing.expectEqual(@as(c_int, 3), step.x);
    try std.testing.expectEqual(@as(c_int, 2), step.y);
    try std.testing.expectEqual(@as(c_int, 0), step.prevdelim);
    try std.testing.expectEqual(@as(u32, 'b'), step.prevrune);
}

test "selection word snap step breaks on line end or delimiter" {
    try std.testing.expectEqual(@as(c_int, sel_snap_word_break), st_selsnapwordstep(6, 2, 6, 0, 0, 0, 'b', 'a').action);
    try std.testing.expectEqual(@as(c_int, sel_snap_word_break), st_selsnapwordstep(3, 2, 6, 0, 1, 0, ',', 'a').action);
}

test "search hit requires active matching row and x range" {
    try std.testing.expectEqual(@as(c_int, 1), st_searchhit(1, 2, 2, 4, 4, 7, 5, 3));
    try std.testing.expectEqual(@as(c_int, 0), st_searchhit(1, 2, 2, 4, 4, 9, 5, 3));
}

test "search line match skips dummy cells" {
    const line = [_]ZigGlyph{
        .{ .u = '你', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = 0, .mode = attr_wdummy, .fg = 0, .bg = 0 },
        .{ .u = '好', .mode = 0, .fg = 0, .bg = 0 },
    };
    const query = [_]u32{ '你', '好' };

    try std.testing.expectEqual(@as(c_int, 3), st_searchlinematch(&line, 0, line.len, &query, query.len, line.len));
    try std.testing.expectEqual(@as(c_int, 0), st_searchlinematch(&line, 1, line.len, &query, query.len, line.len));
}

test "search current valid checks active and bounds" {
    try std.testing.expectEqual(@as(c_int, 1), st_searchcurrentvalid(1, 0, 1));
    try std.testing.expectEqual(@as(c_int, 0), st_searchcurrentvalid(0, 0, 1));
    try std.testing.expectEqual(@as(c_int, 0), st_searchcurrentvalid(1, 2, 1));
}

test "search next current preserves valid old current" {
    try std.testing.expectEqual(@as(c_int, -1), st_searchnextcurrent(2, 0));
    try std.testing.expectEqual(@as(c_int, 2), st_searchnextcurrent(2, 5));
    try std.testing.expectEqual(@as(c_int, 0), st_searchnextcurrent(8, 5));
}

test "search jump changes scroll only for valid different target" {
    try std.testing.expectEqual(@as(c_int, 3), st_searchjumpscr(1, 0, 3));
    try std.testing.expectEqual(@as(c_int, 0), st_searchjumpscr(0, 0, 3));
}

test "search step wraps in both directions" {
    try std.testing.expectEqual(@as(c_int, 0), st_searchstep(1, 3, 2, 1).current);
    try std.testing.expectEqual(@as(c_int, 2), st_searchstep(1, 3, 0, -1).current);
    try std.testing.expectEqual(@as(c_int, 0), st_searchstep(0, 3, 1, 1).run);
}

test "search char movement skips utf8 continuation bytes" {
    const input = "a你b";

    try std.testing.expectEqual(@as(usize, 1), st_searchprevchar(input, 4));
    try std.testing.expectEqual(@as(usize, 4), st_searchnextchar(input, 1, input.len));
}

test "search delete word skips spaces then word" {
    const input = "abc  你好";

    try std.testing.expectEqual(@as(usize, 5), st_searchdeletewordstart(input, input.len));
}

test "search input cap doubles until required fits" {
    try std.testing.expectEqual(@as(usize, 64), st_searchinputcap(0, 3, 0));
    try std.testing.expectEqual(@as(usize, 128), st_searchinputcap(63, 2, 64));
    try std.testing.expectEqual(@as(c_int, 0), st_searchinputgrow(3, 2, 8));
    try std.testing.expectEqual(@as(c_int, 1), st_searchinputgrow(7, 2, 8));
}

test "search input edit plans guard inactive and empty cases" {
    try std.testing.expectEqual(@as(c_int, 0), st_searchinputplan(0, 3));
    try std.testing.expectEqual(@as(c_int, 0), st_searchinputplan(1, 0));
    try std.testing.expectEqual(@as(c_int, 1), st_searchinputplan(1, 3));
    try std.testing.expectEqual(@as(c_int, 0), st_searchbackspaceplan(1, 3, 0));
    try std.testing.expectEqual(@as(c_int, 1), st_searchbackspaceplan(1, 3, 2));
    try std.testing.expectEqual(@as(c_int, 0), st_searchdeleteforwardplan(1, 3, 3));
    try std.testing.expectEqual(@as(c_int, 1), st_searchdeleteforwardplan(1, 2, 3));
    try std.testing.expectEqual(@as(c_int, 0), st_searchdeletewordplan(1, 0));
    try std.testing.expectEqual(@as(c_int, 1), st_searchcursorplan(1));
    try std.testing.expectEqual(@as(c_int, 1), st_searchscanplan(1, 2));
}

test "search delete plan validates range and updates length" {
    try std.testing.expectEqual(@as(c_int, 1), st_searchdeleteplan(2, 5, 9).run);
    try std.testing.expectEqual(@as(usize, 6), st_searchdeleteplan(2, 5, 9).new_len);
    try std.testing.expectEqual(@as(c_int, 0), st_searchdeleteplan(5, 2, 9).run);
}

test "search commit and cancel plans report actions" {
    try std.testing.expectEqual(@as(c_int, search_action_none), st_searchcommitplan(0, 1));
    try std.testing.expectEqual(@as(c_int, search_action_clear), st_searchcommitplan(1, 0));
    try std.testing.expectEqual(@as(c_int, search_action_set), st_searchcommitplan(1, 3));
    try std.testing.expectEqual(@as(c_int, search_action_redraw), st_searchcancelplan(1));
    try std.testing.expectEqual(@as(c_int, 1), st_searchclearinputplan(1));
    try std.testing.expectEqual(@as(c_int, 0), st_searchclearinputplan(0));
    try std.testing.expectEqual(@as(c_int, 1), st_searchbaractive(1, 0));
    try std.testing.expectEqual(@as(c_int, 1), st_searchbaractive(0, 1));
    try std.testing.expectEqual(@as(c_int, 0), st_searchbaractive(0, 0));
}

test "external pipe line plan handles break skip and write" {
    try std.testing.expectEqual(@as(c_int, externalpipe_break), st_externalpipelinelen(-1, 10).kind);
    try std.testing.expectEqual(@as(c_int, externalpipe_skip), st_externalpipelinelen(0, 10).kind);
    try std.testing.expectEqual(@as(c_int, externalpipe_write), st_externalpipelinelen(3, 10).kind);
    try std.testing.expectEqual(@as(c_int, 3), st_externalpipelinelen(3, 10).lastpos);
    try std.testing.expectEqual(@as(c_int, 1), st_externalpipewrap(attr_wrap));
    try std.testing.expectEqual(@as(c_int, 0), st_externalpipewrap(0));
}

test "search set plan keeps allocation nonzero and resets current" {
    const empty = st_searchsetplan(0, 0);
    const active = st_searchsetplan(6, 2);

    try std.testing.expectEqual(@as(usize, 1), empty.alloc_len);
    try std.testing.expectEqual(@as(c_int, 0), empty.active);
    try std.testing.expectEqual(@as(c_int, 1), active.active);
    try std.testing.expectEqual(@as(c_int, -1), active.current);
}

test "search prompt plan allocates missing input buffer" {
    const missing = st_searchpromptplan(0, 0);
    const existing = st_searchpromptplan(1, 128);

    try std.testing.expectEqual(@as(c_int, 1), missing.inputmode);
    try std.testing.expectEqual(@as(c_int, 1), missing.alloc);
    try std.testing.expectEqual(@as(usize, 64), missing.inputcap);
    try std.testing.expectEqual(@as(c_int, 0), existing.alloc);
    try std.testing.expectEqual(@as(usize, 128), existing.inputcap);
}

test "search match cap grows only when full" {
    try std.testing.expectEqual(@as(c_int, 16), st_searchmatchcap(0, 0));
    try std.testing.expectEqual(@as(c_int, 32), st_searchmatchcap(16, 16));
    try std.testing.expectEqual(@as(c_int, 16), st_searchmatchcap(3, 16));
}

test "get selection line plan handles regular multiline" {
    const first = st_getsellineplan(sel_regular, 3, 2, 5, 4, 2, 10);
    const middle = st_getsellineplan(sel_regular, 3, 2, 5, 4, 3, 10);

    try std.testing.expectEqual(@as(c_int, 3), first.start_x);
    try std.testing.expectEqual(@as(c_int, 9), middle.last_x);
}

test "get selection line plan keeps rectangular bounds" {
    const plan = st_getsellineplan(sel_rectangular, 3, 2, 5, 4, 3, 10);

    try std.testing.expectEqual(@as(c_int, 3), plan.start_x);
    try std.testing.expectEqual(@as(c_int, 5), plan.last_x);
}

test "get selection buffer and last column plans" {
    try std.testing.expectEqual(@as(c_int, 88), st_getselbufsize(10, 2, 3, 4));
    try std.testing.expectEqual(@as(c_int, 4), st_getsellastx(9, 5));
}

test "get selection newline follows wrap and rectangular mode" {
    try std.testing.expectEqual(@as(c_int, 1), st_getselnewline(0, 1, 3, 5, 0, sel_regular));
    try std.testing.expectEqual(@as(c_int, 0), st_getselnewline(0, 1, 3, 5, attr_wrap, sel_regular));
    try std.testing.expectEqual(@as(c_int, 1), st_getselnewline(0, 1, 3, 5, attr_wrap, sel_rectangular));
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

test "selection normalize cols adjusts regular edges" {
    const bounds = st_planselnormalizecols(sel_regular, 8, 9, 5, 9, 10);

    try std.testing.expectEqual(@as(c_int, 5), bounds.nb_x);
    try std.testing.expectEqual(@as(c_int, 9), bounds.ne_x);
}
