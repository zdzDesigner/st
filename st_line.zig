//! st_line.zig 承载剩余 C 侧无副作用的行/选择区/列位置判断逻辑。
//! [输入]: C 侧传入只读 glyph 行、终端列数、tab stops，以及 selection 的值拷贝字段。
//! [输出]: 行有效长度、dump 输出范围、tab 跳转目标列，或指定坐标是否落在当前 selection 内。
//! [副作用边界]: 不访问全局 `term` / `sel`，不修改 glyph、dirty、selection，也不做 IO/分配/X11 调用。
//! [定位]: 替代 `tlinelen(...)`、`tlinehistlen(...)`、`tputtab(...)` 的扫描主体、`selected(...)` 的纯判断主体，以及 `selnormalize(...)` 的 bounds 计算主体。

const std = @import("std");
const selection = @import("st_selection.zig");

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

const attr_wrap: c_ushort = 1 << 8;
const attr_wdummy: c_ushort = 1 << 10;
const sel_regular = 1;
const sel_empty = 1;
const sel_rectangular = 2;
const sel_scroll_none = 0;
const sel_scroll_clear = 1;
const sel_scroll_normalize = 2;
const sel_snap_word_break = 0;
const sel_snap_word_accept = 1;
const search_action_none = 0;
const search_action_clear = 1;
const search_action_set = 2;
const search_action_redraw = 3;
const externalpipe_break = 0;
const externalpipe_skip = 1;
const externalpipe_write = 2;

export fn st_tlinelen(line: [*]const ZigGlyph, col: c_int) c_int {
    var i = col;

    if ((line[@intCast(i - 1)].mode & attr_wrap) != 0) return i;

    while (i > 0 and line[@intCast(i - 1)].u == ' ') {
        i -= 1;
    }

    return i;
}

export fn st_tputtab(x: c_int, col: c_int, n: c_int, tabs: [*]const c_int) c_int {
    var next_x = x;

    if (n > 0) {
        var remaining = n;
        while (next_x < col and remaining > 0) : (remaining -= 1) {
            next_x += 1;
            while (next_x < col and tabs[@intCast(next_x)] == 0) {
                next_x += 1;
            }
        }
    } else if (n < 0) {
        var remaining = n;
        while (next_x > 0 and remaining < 0) : (remaining += 1) {
            next_x -= 1;
            while (next_x > 0 and tabs[@intCast(next_x)] == 0) {
                next_x -= 1;
            }
        }
    }

    return limitInt(next_x, 0, col - 1);
}

export fn st_tattrset(lines: [*]const [*]const ZigGlyph, row: c_int, col: c_int, attr: c_int) c_int {
    const mask = attrMask(attr);
    var y: c_int = 0;

    while (y < row - 1) : (y += 1) {
        if (lineHasAttr(lines[@intCast(y)], col, mask)) return 1;
    }

    return 0;
}

export fn st_tlineattrset(line: [*]const ZigGlyph, col: c_int, attr: c_int) c_int {
    return if (lineHasAttr(line, col, attrMask(attr))) 1 else 0;
}

export fn st_tdumplineplan(linelen: c_int, col: c_int) ZigDumpLinePlan {
    const end = minInt(linelen, col);
    return .{
        .write = if (end > 0) 1 else 0,
        .last = end - 1,
    };
}

export fn st_tsetdirtrange(top: c_int, bot: c_int, row: c_int) ZigLineRange {
    return .{
        .top = limitInt(top, 0, row - 1),
        .bot = limitInt(bot, 0, row - 1),
    };
}

export fn st_selscrollplan(ob_x: c_int, ob_y: c_int, oe_y: c_int, nb_y: c_int, ne_y: c_int, orig: c_int, top: c_int, bot: c_int, n: c_int) ZigSelScrollPlan {
    const plan = selection.scrollPlan(ob_x, ob_y, oe_y, .{ .start = .{ .x = 0, .y = nb_y }, .end = .{ .x = 0, .y = ne_y } }, orig, top, bot, n);
    return .{ .action = @intFromEnum(plan.action), .ob_y = plan.origin_y, .oe_y = plan.extent_y };
}

export fn st_selextendplan(old_oe_x: c_int, old_oe_y: c_int, old_type: c_int, old_nb_y: c_int, old_ne_y: c_int, new_oe_x: c_int, new_oe_y: c_int, new_type: c_int, new_nb_y: c_int, new_ne_y: c_int, old_mode: c_int, done: c_int) ZigSelExtendPlan {
    const old_selection_type: selection.SelectionType = if (old_type == sel_rectangular) .rectangular else .regular;
    const new_selection_type: selection.SelectionType = if (new_type == sel_rectangular) .rectangular else .regular;
    const mode: selection.SelectionMode = if (old_mode == sel_empty) .empty else if (old_mode == 0) .idle else .ready;
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
        .dirty = if (plan.dirty) 1 else 0,
        .top = plan.top,
        .bot = plan.bot,
        .mode = @intFromEnum(plan.mode),
    };
}

export fn st_selclearplan(ob_x: c_int) c_int {
    return if (selection.shouldClear(ob_x)) 1 else 0;
}

export fn st_selstartplan(col: c_int, row: c_int, snap: c_int, alt_screen: c_int) ZigSelStartPlan {
    const plan = selection.startPlan(.{ .x = col, .y = row }, snap, alt_screen != 0);
    return .{
        .mode = @intFromEnum(plan.mode),
        .sel_type = @intFromEnum(plan.selection_type),
        .alt = if (plan.alt) 1 else 0,
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
        .wrapped = if (plan.wrapped) 1 else 0,
        .in_bounds = if (plan.in_bounds) 1 else 0,
    };
}

export fn st_selsnapwordbreak(mode: c_ushort, delim: c_int, prevdelim: c_int, rune: u32, prevrune: u32) c_int {
    const prev = selection.SnapPrev{ .delim = prevdelim, .rune = prevrune };
    return if (selection.snapWordBreak(mode, delim, prev, rune)) 1 else 0;
}

export fn st_selsnapwordpastline(x: c_int, linelen: c_int) c_int {
    return if (selection.snapWordPastLine(x, linelen)) 1 else 0;
}

export fn st_selsnapwordstep(x: c_int, y: c_int, linelen: c_int, mode: c_ushort, delim: c_int, prevdelim: c_int, rune: u32, prevrune: u32) ZigSelSnapWordStep {
    const step = selection.snapWordStep(.{ .x = x, .y = y }, linelen, mode, delim, .{ .delim = prevdelim, .rune = prevrune }, rune);
    switch (step) {
        .stop => |prev| return .{ .action = sel_snap_word_break, .x = x, .y = y, .prevdelim = prev.delim, .prevrune = prev.rune },
        .accept => |accepted| return .{ .action = sel_snap_word_accept, .x = accepted.point.x, .y = accepted.point.y, .prevdelim = accepted.prev.delim, .prevrune = accepted.prev.rune },
    }
}

export fn st_selected(x: c_int, y: c_int, mode: c_int, ob_x: c_int, sel_alt: c_int, alt_screen: c_int, sel_type: c_int, nb_x: c_int, nb_y: c_int, ne_x: c_int, ne_y: c_int) c_int {
    const selection_type: selection.SelectionType = if (sel_type == sel_rectangular) .rectangular else .regular;
    const bounds = selection.Bounds{ .start = .{ .x = nb_x, .y = nb_y }, .end = .{ .x = ne_x, .y = ne_y } };
    const active = mode != sel_empty and ob_x != -1;
    return if (selection.isSelected(.{ .x = x, .y = y }, active, sel_alt == alt_screen, selection_type, bounds)) 1 else 0;
}

export fn st_searchcurrentvalid(active: c_int, current: c_int, nmatches: c_int) c_int {
    return if (active != 0 and current >= 0 and current < nmatches) 1 else 0;
}

export fn st_searchhit(active: c_int, match_scr: c_int, term_scr: c_int, match_y: c_int, y: c_int, x: c_int, match_x: c_int, match_len: c_int) c_int {
    return if (active != 0 and match_scr == term_scr and match_y == y and between(x, match_x, match_x + match_len - 1)) 1 else 0;
}

export fn st_searchlinematch(line: [*]const ZigGlyph, x: c_int, linelen: c_int, query: [*]const u32, qlen: c_int, col: c_int) c_int {
    if ((line[@intCast(x)].mode & attr_wdummy) != 0) return 0;

    var pos = x;
    var i: c_int = 0;
    while (i < qlen) : (i += 1) {
        while (pos < linelen and (line[@intCast(pos)].mode & attr_wdummy) != 0) {
            pos += 1;
        }
        if (pos >= linelen or line[@intCast(pos)].u != query[@intCast(i)]) return 0;
        pos += 1;
    }
    while (pos < col and (line[@intCast(pos)].mode & attr_wdummy) != 0) {
        pos += 1;
    }
    return pos - x;
}

export fn st_searchnextcurrent(oldcurrent: c_int, nmatches: c_int) c_int {
    if (nmatches == 0) return -1;
    if (between(oldcurrent, 0, nmatches - 1)) return oldcurrent;
    return 0;
}

export fn st_searchjumpscr(current_valid: c_int, term_scr: c_int, match_scr: c_int) c_int {
    if (current_valid == 0) return term_scr;
    return if (term_scr != match_scr) match_scr else term_scr;
}

export fn st_searchstep(active: c_int, nmatches: c_int, current: c_int, direction: c_int) ZigSearchStepPlan {
    if (active == 0 or nmatches == 0) return .{ .run = 0, .current = current };
    return .{
        .run = 1,
        .current = @mod(current + nmatches + direction, nmatches),
    };
}

export fn st_searchprevchar(input: [*]const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var next = cursor - 1;
    while (next > 0 and (input[next] & 0xc0) == 0x80) {
        next -= 1;
    }
    return next;
}

export fn st_searchnextchar(input: [*]const u8, cursor: usize, inputlen: usize) usize {
    if (cursor >= inputlen) return inputlen;
    var next = cursor + 1;
    while (next < inputlen and (input[next] & 0xc0) == 0x80) {
        next += 1;
    }
    return next;
}

export fn st_searchdeletewordstart(input: [*]const u8, cursor: usize) usize {
    var start = cursor;
    while (start > 0 and input[st_searchprevchar(input, start)] == ' ') {
        start = st_searchprevchar(input, start);
    }
    while (start > 0 and input[st_searchprevchar(input, start)] != ' ') {
        start = st_searchprevchar(input, start);
    }
    return start;
}

export fn st_searchinputcap(inputlen: usize, add_len: usize, inputcap: usize) usize {
    const required = inputlen + add_len + 1;
    var next_cap = inputcap;
    while (required > next_cap) {
        next_cap = if (next_cap != 0) next_cap * 2 else 64;
    }
    return next_cap;
}

export fn st_searchinputgrow(inputlen: usize, add_len: usize, inputcap: usize) c_int {
    return if (inputlen + add_len + 1 > inputcap) 1 else 0;
}

export fn st_searchinputplan(inputmode: c_int, len: usize) c_int {
    return if (inputmode != 0 and len != 0) 1 else 0;
}

export fn st_searchbackspaceplan(inputmode: c_int, inputlen: usize, cursor: usize) c_int {
    return if (inputmode != 0 and inputlen != 0 and cursor != 0) 1 else 0;
}

export fn st_searchdeleteforwardplan(inputmode: c_int, cursor: usize, inputlen: usize) c_int {
    return if (inputmode != 0 and cursor < inputlen) 1 else 0;
}

export fn st_searchdeletewordplan(inputmode: c_int, cursor: usize) c_int {
    return if (inputmode != 0 and cursor != 0) 1 else 0;
}

export fn st_searchcursorplan(inputmode: c_int) c_int {
    return if (inputmode != 0) 1 else 0;
}

export fn st_searchscanplan(active: c_int, qlen: c_int) c_int {
    return if (active != 0 and qlen > 0) 1 else 0;
}

export fn st_searchdeleteplan(start: usize, end: usize, inputlen: usize) ZigSearchDeletePlan {
    if (start >= end or end > inputlen) return .{ .run = 0, .new_len = inputlen };
    return .{ .run = 1, .new_len = inputlen - (end - start) };
}

export fn st_searchcommitplan(inputmode: c_int, inputlen: usize) c_int {
    if (inputmode == 0) return search_action_none;
    return if (inputlen == 0) search_action_clear else search_action_set;
}

export fn st_searchcancelplan(inputmode: c_int) c_int {
    return if (inputmode != 0) search_action_redraw else search_action_none;
}

export fn st_searchclearinputplan(inputmode: c_int) c_int {
    return if (inputmode != 0) 1 else 0;
}

export fn st_searchbaractive(inputmode: c_int, active: c_int) c_int {
    return if (inputmode != 0 or active != 0) 1 else 0;
}

export fn st_externalpipelinelen(linelen: c_int, col: c_int) ZigExternalPipeLinePlan {
    const lastpos = minInt(linelen + 1, col) - 1;
    if (lastpos < 0) return .{ .kind = externalpipe_break, .lastpos = lastpos };
    if (lastpos == 0) return .{ .kind = externalpipe_skip, .lastpos = lastpos };
    return .{ .kind = externalpipe_write, .lastpos = lastpos };
}

export fn st_externalpipewrap(mode: c_ushort) c_int {
    return if ((mode & attr_wrap) != 0) 1 else 0;
}

export fn st_searchpromptplan(has_input: c_int, inputcap: usize) ZigSearchPromptPlan {
    return .{
        .inputmode = 1,
        .inputlen = 0,
        .inputcursor = 0,
        .alloc = if (has_input == 0) 1 else 0,
        .inputcap = if (has_input == 0) 64 else inputcap,
    };
}

export fn st_searchsetplan(query_len: usize, qlen: c_int) ZigSearchSetPlan {
    return .{
        .alloc_len = if (query_len != 0) query_len else 1,
        .active = if (qlen > 0) 1 else 0,
        .current = -1,
    };
}

export fn st_searchmatchcap(nmatches: c_int, cap: c_int) c_int {
    if (nmatches != cap) return cap;
    return if (cap != 0) cap * 2 else 16;
}

export fn st_getsellineplan(sel_type: c_int, nb_x: c_int, nb_y: c_int, ne_x: c_int, ne_y: c_int, y: c_int, col: c_int) ZigGetSelLinePlan {
    const selection_type: selection.SelectionType = if (sel_type == sel_rectangular) .rectangular else .regular;
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
    const selection_type: selection.SelectionType = if (sel_type == sel_rectangular) .rectangular else .regular;
    return if (selection.needsNewline(y, .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 0, .y = ne_y } }, last_x, linelen, last_mode, selection_type)) 1 else 0;
}

export fn st_planselnormalize(sel_type: c_int, ob_x: c_int, ob_y: c_int, oe_x: c_int, oe_y: c_int) ZigSelBounds {
    const selection_type: selection.SelectionType = if (sel_type == sel_rectangular) .rectangular else .regular;
    const bounds = selection.normalize(selection_type, .{ .x = ob_x, .y = ob_y }, .{ .x = oe_x, .y = oe_y });
    return .{ .nb_x = bounds.start.x, .nb_y = bounds.start.y, .ne_x = bounds.end.x, .ne_y = bounds.end.y };
}

export fn st_planselnormalizecols(sel_type: c_int, nb_x: c_int, ne_x: c_int, nb_len: c_int, ne_len: c_int, col: c_int) ZigSelBounds {
    const selection_type: selection.SelectionType = if (sel_type == sel_rectangular) .rectangular else .regular;
    const bounds = selection.normalizeColumns(selection_type, .{ .start = .{ .x = nb_x, .y = 0 }, .end = .{ .x = ne_x, .y = 0 } }, nb_len, ne_len, col);
    return .{ .nb_x = bounds.start.x, .nb_y = 0, .ne_x = bounds.end.x, .ne_y = 0 };
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

fn limitInt(value: c_int, lower: c_int, upper: c_int) c_int {
    if (value < lower) return lower;
    if (value > upper) return upper;
    return value;
}

fn attrMask(attr: c_int) c_ushort {
    return @truncate(@as(c_uint, @bitCast(attr)));
}

fn lineHasAttr(line: [*]const ZigGlyph, col: c_int, mask: c_ushort) bool {
    var x: c_int = 0;
    while (x < col - 1) : (x += 1) {
        if ((line[@intCast(x)].mode & mask) != 0) return true;
    }
    return false;
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
