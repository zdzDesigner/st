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

const ZigSelSnapLineStep = extern struct {
    action: c_int,
    y: c_int,
};

const ZigGetSelExecPlan = extern struct {
    empty: c_int,
    start_x: c_int,
    last_index: c_int,
    newline: c_int,
    bufsize: c_int,
};

const ZigSearchStepPlan = extern struct {
    run: c_int,
    current: c_int,
};

const ZigSearchDeletePlan = extern struct {
    run: c_int,
    new_len: usize,
};

const ZigSearchInsertPlan = extern struct {
    run: c_int,
    grow: c_int,
    inputcap: usize,
    insert_at: usize,
    move_dst: usize,
    move_src: usize,
    move_len: usize,
    new_len: usize,
    new_cursor: usize,
};

const ZigSearchCursorEditPlan = extern struct {
    kind: c_int,
    start: usize,
    end: usize,
    cursor: usize,
};

const ZigSearchMatch = search.SearchMatch;

const ZigSearchLinePlan = extern struct {
    kind: c_int,
    cap: c_int,
    next_x: c_int,
    match: ZigSearchMatch,
};

const ZigSearchStateEditPlan = extern struct {
    kind: c_int,
    inputlen: usize,
    inputcursor: usize,
};

const ZigSearchSetPlan = extern struct {
    alloc_len: usize,
    active: c_int,
    current: c_int,
};

const ZigSearchSnapshot = extern struct {
    query_len: c_int,
    inputmode: c_int,
    inputlen: usize,
    inputcursor: usize,
    inputcap: usize,
    nmatches: c_int,
    match_cap: c_int,
    current: c_int,
    active: c_int,
};

const ZigSearchStateUpdate = extern struct {
    active: c_int,
    current: c_int,
    inputmode: c_int,
    inputlen: usize,
    inputcursor: usize,
    inputcap: usize,
    nmatches: c_int,
    match_cap: c_int,
};

const ZigSearchEffectPlan = extern struct {
    alloc_input: c_int,
    realloc_input: c_int,
    alloc_query: c_int,
    realloc_matches: c_int,
    clear_query: c_int,
    clear_matches: c_int,
    refresh_search: c_int,
    redraw: c_int,
    jump: c_int,
};

const ZigSearchPromptResult = extern struct {
    update: ZigSearchStateUpdate,
    effect: ZigSearchEffectPlan,
};

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

export fn st_selsnaplinestep(y: c_int, direction: c_int, row: c_int, wrapped: c_int) ZigSelSnapLineStep {
    const step = selection.snapLineStep(y, direction, row, wrapped != 0);
    return switch (step) {
        .stop => |next_y| .{ .action = sel_snap_line_stop, .y = next_y },
        .move => |next_y| .{ .action = sel_snap_line_move, .y = next_y },
    };
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

export fn st_selsnapwordloopstep(x: c_int, y: c_int, wrap_x: c_int, wrap_y: c_int, wrapped: c_int, in_bounds: c_int, wrap_allowed: c_int, linelen: c_int, mode: c_ushort, delim: c_int, prevdelim: c_int, rune: u32, prevrune: u32) ZigSelSnapWordStep {
    const step = selection.snapWordLoopStep(
        .{
            .point = .{ .x = x, .y = y },
            .wrap_point = .{ .x = wrap_x, .y = wrap_y },
            .wrapped = wrapped != 0,
            .in_bounds = in_bounds != 0,
        },
        wrap_allowed != 0,
        linelen,
        mode,
        delim,
        .{ .delim = prevdelim, .rune = prevrune },
        rune,
    );
    return switch (step) {
        .stop => |prev| .{ .action = sel_snap_word_break, .x = x, .y = y, .prevdelim = prev.delim, .prevrune = prev.rune },
        .accept => |accepted| .{ .action = sel_snap_word_accept, .x = accepted.point.x, .y = accepted.point.y, .prevdelim = accepted.prev.delim, .prevrune = accepted.prev.rune },
    };
}

export fn st_selected(x: c_int, y: c_int, mode: c_int, ob_x: c_int, sel_alt: c_int, alt_screen: c_int, sel_type: c_int, nb_x: c_int, nb_y: c_int, ne_x: c_int, ne_y: c_int) c_int {
    const selection_type = selectionType(sel_type);
    const bounds = selection.Bounds{ .start = .{ .x = nb_x, .y = nb_y }, .end = .{ .x = ne_x, .y = ne_y } };
    const active = mode != sel_empty and ob_x != -1;
    return boolInt(selection.isSelected(.{ .x = x, .y = y }, active, sel_alt == alt_screen, selection_type, bounds));
}

export fn st_searchmatchlist(matches: ?[*]const ZigSearchMatch, nmatches: c_int, active: c_int, current: c_int, term_scr: c_int, x: c_int, y: c_int) c_int {
    const count: usize = if (nmatches > 0) @intCast(nmatches) else 0;
    const items = if (count == 0) &[_]ZigSearchMatch{} else (matches orelse return 0)[0..count];
    return boolInt(search.matchListContains(items, active != 0, current, term_scr, x, y));
}

export fn st_searchcurrentmatch(matches: ?[*]const ZigSearchMatch, nmatches: c_int, active: c_int, current: c_int, term_scr: c_int, x: c_int, y: c_int) c_int {
    const count: usize = if (nmatches > 0) @intCast(nmatches) else 0;
    const items = if (count == 0) &[_]ZigSearchMatch{} else (matches orelse return 0)[0..count];
    return boolInt(search.matchListCurrent(items, active != 0, current, term_scr, x, y));
}

export fn st_searchlineplan(line: [*]const ZigGlyph, start_x: c_int, col: c_int, query: [*]const u32, qlen: c_int, nmatches: c_int, cap: c_int, y: c_int, scr: c_int) ZigSearchLinePlan {
    const glyphs = line[0..@intCast(col)];
    const linelen = (line_core.Line(ZigGlyph){ .glyphs = glyphs, .cols = col }).length();
    const last_x = search.scanLineLastStart(linelen, qlen);
    var x = start_x;
    while (x <= last_x) : (x += 1) {
        const match_len = search.lineMatch(ZigGlyph, glyphs, x, linelen, query[0..@intCast(qlen)], col);
        const plan = search.appendMatch(match_len, nmatches, cap, x, y, scr);
        switch (plan) {
            .skip => {},
            .append => |match| return .{ .kind = @intFromEnum(search.MatchAppendKind.append), .cap = cap, .next_x = x + 1, .match = match },
            .grow_append => |grow| return .{ .kind = @intFromEnum(search.MatchAppendKind.grow_append), .cap = grow.cap, .next_x = x + 1, .match = grow.match },
        }
    }
    return .{ .kind = @intFromEnum(search.MatchAppendKind.skip), .cap = cap, .next_x = x, .match = .{ .x = 0, .y = 0, .scr = 0, .len = 0 } };
}

export fn st_tlinehistplan(y: c_int, histsize: c_int, rows: c_int) ZigHistoryLinePlan {
    const plan = search.historyLine(y, histsize, rows);
    return .{ .hist = boolInt(plan.hist), .index = plan.index };
}

export fn st_searchstep(active: c_int, nmatches: c_int, current: c_int, direction: c_int) ZigSearchStepPlan {
    const plan = search.step(active != 0, nmatches, current, direction);
    return .{
        .run = boolInt(plan.run),
        .current = plan.current,
    };
}

fn searchCursorEditPlan(edit: search.CursorEdit) ZigSearchCursorEditPlan {
    return switch (edit) {
        .none => .{ .kind = @intFromEnum(search.CursorEditKind.none), .start = 0, .end = 0, .cursor = 0 },
        .delete => |delete| .{ .kind = @intFromEnum(search.CursorEditKind.delete), .start = delete.start, .end = delete.end, .cursor = delete.cursor },
        .move => |cursor| .{ .kind = @intFromEnum(search.CursorEditKind.move), .start = 0, .end = 0, .cursor = cursor },
    };
}

fn searchStateEditPlan(edit: search.StateEdit) ZigSearchStateEditPlan {
    return switch (edit) {
        .none => .{ .kind = @intFromEnum(search.StateEditKind.none), .inputlen = 0, .inputcursor = 0 },
        .clear_input => |clear| .{ .kind = @intFromEnum(search.StateEditKind.clear_input), .inputlen = clear.len, .inputcursor = clear.cursor },
        .commit_clear => .{ .kind = @intFromEnum(search.StateEditKind.commit_clear), .inputlen = 0, .inputcursor = 0 },
        .commit_set => .{ .kind = @intFromEnum(search.StateEditKind.commit_set), .inputlen = 0, .inputcursor = 0 },
        .cancel => .{ .kind = @intFromEnum(search.StateEditKind.cancel), .inputlen = 0, .inputcursor = 0 },
    };
}

export fn st_searchbackspaceedit(input: [*]const u8, inputmode: c_int, inputlen: usize, cursor: usize) ZigSearchCursorEditPlan {
    return searchCursorEditPlan(search.cursorEdit(input[0..inputlen], inputmode != 0, inputlen, cursor, .backspace));
}

export fn st_searchdeleteforwardedit(input: [*]const u8, inputmode: c_int, inputlen: usize, cursor: usize) ZigSearchCursorEditPlan {
    return searchCursorEditPlan(search.cursorEdit(input[0..inputlen], inputmode != 0, inputlen, cursor, .delete_forward));
}

export fn st_searchdeletewordedit(input: [*]const u8, inputmode: c_int, inputlen: usize, cursor: usize) ZigSearchCursorEditPlan {
    return searchCursorEditPlan(search.cursorEdit(input[0..inputlen], inputmode != 0, inputlen, cursor, .delete_word));
}

export fn st_searchmoveleftedit(input: [*]const u8, inputmode: c_int, inputlen: usize, cursor: usize) ZigSearchCursorEditPlan {
    return searchCursorEditPlan(search.cursorEdit(input[0..inputlen], inputmode != 0, inputlen, cursor, .move_left));
}

export fn st_searchmoverightedit(input: [*]const u8, inputmode: c_int, inputlen: usize, cursor: usize) ZigSearchCursorEditPlan {
    return searchCursorEditPlan(search.cursorEdit(input[0..inputlen], inputmode != 0, inputlen, cursor, .move_right));
}

export fn st_searchhomeedit(inputmode: c_int) ZigSearchCursorEditPlan {
    return searchCursorEditPlan(search.cursorEdit(&.{}, inputmode != 0, 0, 0, .home));
}

export fn st_searchendedit(inputmode: c_int, inputlen: usize) ZigSearchCursorEditPlan {
    return searchCursorEditPlan(search.cursorEdit(&.{}, inputmode != 0, inputlen, inputlen, .end));
}

export fn st_searchclearinputedit(inputmode: c_int) ZigSearchStateEditPlan {
    return searchStateEditPlan(search.clearInputEdit(inputmode != 0));
}

export fn st_searchcommitedit(inputmode: c_int, inputlen: usize) ZigSearchStateEditPlan {
    return searchStateEditPlan(search.commitEdit(inputmode != 0, inputlen));
}

export fn st_searchcanceledit(inputmode: c_int) ZigSearchStateEditPlan {
    return searchStateEditPlan(search.cancelEdit(inputmode != 0));
}

export fn st_searchinsertplan(inputmode: c_int, inputlen: usize, cursor: usize, inputcap: usize, add_len: usize) ZigSearchInsertPlan {
    const plan = search.insertPlan(inputmode != 0, inputlen, cursor, inputcap, add_len);
    return .{
        .run = boolInt(plan.run),
        .grow = boolInt(plan.grow),
        .inputcap = plan.inputcap,
        .insert_at = plan.insert_at,
        .move_dst = plan.move_dst,
        .move_src = plan.move_src,
        .move_len = plan.move_len,
        .new_len = plan.new_len,
        .new_cursor = plan.new_cursor,
    };
}

export fn st_searchdeleteplan(start: usize, end: usize, inputlen: usize) ZigSearchDeletePlan {
    const plan = search.deletePlan(start, end, inputlen);
    return .{ .run = boolInt(plan.run), .new_len = plan.new_len };
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
    const result = search.promptResult(.{
        .query_len = snapshot.query_len,
        .inputmode = snapshot.inputmode != 0,
        .inputlen = snapshot.inputlen,
        .inputcursor = snapshot.inputcursor,
        .inputcap = snapshot.inputcap,
        .nmatches = snapshot.nmatches,
        .match_cap = snapshot.match_cap,
        .current = snapshot.current,
        .active = snapshot.active != 0,
    });
    return .{
        .update = .{
            .active = boolInt(result.update.active),
            .current = result.update.current,
            .inputmode = boolInt(result.update.inputmode),
            .inputlen = result.update.inputlen,
            .inputcursor = result.update.inputcursor,
            .inputcap = result.update.inputcap,
            .nmatches = result.update.nmatches,
            .match_cap = result.update.match_cap,
        },
        .effect = .{
            .alloc_input = boolInt(result.effect.alloc_input),
            .realloc_input = boolInt(result.effect.realloc_input),
            .alloc_query = boolInt(result.effect.alloc_query),
            .realloc_matches = boolInt(result.effect.realloc_matches),
            .clear_query = boolInt(result.effect.clear_query),
            .clear_matches = boolInt(result.effect.clear_matches),
            .refresh_search = boolInt(result.effect.refresh_search),
            .redraw = boolInt(result.effect.redraw),
            .jump = boolInt(result.effect.jump),
        },
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

export fn st_getselexecplan(sel_type: c_int, nb_x: c_int, nb_y: c_int, ne_x: c_int, ne_y: c_int, y: c_int, col: c_int, line: [*]const ZigGlyph, utf_siz: c_int) ZigGetSelExecPlan {
    const selection_type = selectionType(sel_type);
    const bounds = selection.Bounds{ .start = .{ .x = nb_x, .y = nb_y }, .end = .{ .x = ne_x, .y = ne_y } };
    const bufsize = selection.getBufferSize(col, .{ .start = .{ .x = 0, .y = nb_y }, .end = .{ .x = 0, .y = ne_y } }, utf_siz);
    const glyphs = line[0..@intCast(col)];
    const linelen = (line_core.Line(ZigGlyph){ .glyphs = glyphs, .cols = col }).length();

    if (linelen == 0) {
        return .{ .empty = 1, .start_x = 0, .last_index = -1, .newline = 1, .bufsize = bufsize };
    }

    const line_plan = selection.getLinePlan(selection_type, bounds, y, col);
    const start_x = line_plan.start_x;
    var last_index = selection.getLastX(line_plan.last_x, linelen);
    while (last_index >= start_x and glyphs[@intCast(last_index)].u == ' ') {
        last_index -= 1;
    }

    const last_mode: c_ushort = if (last_index >= start_x) glyphs[@intCast(last_index)].mode else 0;
    return .{
        .empty = if (last_index < start_x) 1 else 0,
        .start_x = start_x,
        .last_index = last_index,
        .newline = boolInt(selection.needsNewline(y, .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 0, .y = ne_y } }, line_plan.last_x, linelen, last_mode, selection_type)),
        .bufsize = bufsize,
    };
}

export fn st_selnormalizeplan(sel_type: c_int, ob_x: c_int, ob_y: c_int, oe_x: c_int, oe_y: c_int) ZigSelBounds {
    const selection_type = selectionType(sel_type);
    const bounds = selection.normalize(selection_type, .{ .x = ob_x, .y = ob_y }, .{ .x = oe_x, .y = oe_y });
    return .{ .nb_x = bounds.start.x, .nb_y = bounds.start.y, .ne_x = bounds.end.x, .ne_y = bounds.end.y };
}

export fn st_selnormalizecolsplan(sel_type: c_int, nb_x: c_int, ne_x: c_int, nb_len: c_int, ne_len: c_int, col: c_int) ZigSelBounds {
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
    try std.testing.expectEqual(@as(c_int, sel_snap_line_move), st_selsnaplinestep(3, -1, 5, 1).action);
    try std.testing.expectEqual(@as(c_int, 2), st_selsnaplinestep(3, -1, 5, 1).y);
    try std.testing.expectEqual(@as(c_int, sel_snap_line_stop), st_selsnaplinestep(3, 1, 5, 0).action);
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
    const prev = selection.SnapPrev{ .delim = 0, .rune = 'a' };
    try std.testing.expect(selection.snapWordBreak(0, 1, prev, ','));
    try std.testing.expect(selection.snapWordBreak(0, 1, .{ .delim = 1, .rune = ',' }, '.'));
    try std.testing.expect(!selection.snapWordBreak(attr_wdummy, 1, prev, ','));
    try std.testing.expect(!selection.snapWordBreak(0, 0, prev, 'b'));
    try std.testing.expect(selection.snapWordPastLine(5, 5));
    try std.testing.expect(!selection.snapWordPastLine(4, 5));
}

test "selection word snap step accepts and updates previous glyph" {
    const step = st_selsnapwordloopstep(3, 2, 2, 2, 0, 1, 1, 6, 0, 0, 0, 'b', 'a');
    try std.testing.expectEqual(@as(c_int, sel_snap_word_accept), step.action);
    try std.testing.expectEqual(@as(c_int, 3), step.x);
    try std.testing.expectEqual(@as(c_int, 2), step.y);
    try std.testing.expectEqual(@as(c_int, 0), step.prevdelim);
    try std.testing.expectEqual(@as(u32, 'b'), step.prevrune);
}

test "selection word snap step breaks on line end or delimiter" {
    try std.testing.expectEqual(@as(c_int, sel_snap_word_break), st_selsnapwordloopstep(6, 2, 2, 2, 0, 1, 1, 6, 0, 0, 0, 'b', 'a').action);
    try std.testing.expectEqual(@as(c_int, sel_snap_word_break), st_selsnapwordloopstep(3, 2, 2, 2, 0, 1, 1, 6, 0, 1, 0, ',', 'a').action);
    try std.testing.expectEqual(@as(c_int, sel_snap_word_break), st_selsnapwordloopstep(0, -1, 0, -1, 1, 0, 1, 0, 0, 0, 0, 'a', 'a').action);
    try std.testing.expectEqual(@as(c_int, sel_snap_word_break), st_selsnapwordloopstep(0, 3, 9, 2, 1, 1, 0, 6, 0, 0, 0, 'b', 'a').action);
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

test "search insert plan describes buffer edit" {
    const empty = st_searchinsertplan(1, 0, 0, 8, 2);
    const plan = st_searchinsertplan(1, 3, 1, 8, 2);

    try std.testing.expectEqual(@as(c_int, 1), empty.run);
    try std.testing.expectEqual(@as(usize, 0), empty.insert_at);
    try std.testing.expectEqual(@as(usize, 1), empty.move_len);
    try std.testing.expectEqual(@as(usize, 2), empty.new_len);
    try std.testing.expectEqual(@as(usize, 2), empty.new_cursor);
    try std.testing.expectEqual(@as(c_int, 1), plan.run);
    try std.testing.expectEqual(@as(c_int, 0), plan.grow);
    try std.testing.expectEqual(@as(usize, 1), plan.insert_at);
    try std.testing.expectEqual(@as(usize, 3), plan.move_dst);
    try std.testing.expectEqual(@as(usize, 1), plan.move_src);
    try std.testing.expectEqual(@as(usize, 3), plan.move_len);
    try std.testing.expectEqual(@as(usize, 5), plan.new_len);
    try std.testing.expectEqual(@as(usize, 3), plan.new_cursor);
}

test "search cursor edit adapters expose tagged actions" {
    const input = "abc  你好";
    const backspace = st_searchbackspaceedit(input, 1, input.len, input.len);
    const move_left = st_searchmoveleftedit(input, 1, input.len, input.len);
    const home_edit = st_searchhomeedit(1);
    const end_edit = st_searchendedit(1, input.len);
    const inactive = st_searchbackspaceedit(input, 0, input.len, input.len);

    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.CursorEditKind.delete)), backspace.kind);
    try std.testing.expectEqual(@as(usize, 8), backspace.start);
    try std.testing.expectEqual(@as(usize, input.len), backspace.end);
    try std.testing.expectEqual(@as(usize, 8), backspace.cursor);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.CursorEditKind.move)), move_left.kind);
    try std.testing.expectEqual(@as(usize, 8), move_left.cursor);
    try std.testing.expectEqual(@as(usize, 0), home_edit.cursor);
    try std.testing.expectEqual(@as(usize, input.len), end_edit.cursor);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.CursorEditKind.none)), inactive.kind);
}

test "search state edit adapters expose tagged actions" {
    const clear = st_searchclearinputedit(1);
    const inactive_clear = st_searchclearinputedit(0);
    const commit_clear = st_searchcommitedit(1, 0);
    const commit_set = st_searchcommitedit(1, 3);
    const cancel = st_searchcanceledit(1);

    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.StateEditKind.clear_input)), clear.kind);
    try std.testing.expectEqual(@as(usize, 0), clear.inputlen);
    try std.testing.expectEqual(@as(usize, 0), clear.inputcursor);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.StateEditKind.none)), inactive_clear.kind);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.StateEditKind.commit_clear)), commit_clear.kind);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.StateEditKind.commit_set)), commit_set.kind);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.StateEditKind.cancel)), cancel.kind);
}

test "search input edit plans guard inactive and empty cases" {
    try std.testing.expectEqual(@as(c_int, 0), st_searchbackspaceedit("abc", 1, 3, 0).kind);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.CursorEditKind.delete)), st_searchbackspaceedit("abc", 1, 3, 2).kind);
    try std.testing.expectEqual(@as(c_int, 0), st_searchdeleteforwardedit("abc", 1, 3, 3).kind);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.CursorEditKind.delete)), st_searchdeleteforwardedit("abc", 1, 3, 2).kind);
    try std.testing.expectEqual(@as(c_int, 0), st_searchdeletewordedit("abc", 1, 3, 0).kind);
}

test "search delete plan validates range and updates length" {
    try std.testing.expectEqual(@as(c_int, 1), st_searchdeleteplan(2, 5, 9).run);
    try std.testing.expectEqual(@as(usize, 6), st_searchdeleteplan(2, 5, 9).new_len);
    try std.testing.expectEqual(@as(c_int, 0), st_searchdeleteplan(5, 2, 9).run);
}

test "search commit and cancel plans report actions" {
    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.StateEditKind.none)), st_searchcommitedit(0, 1).kind);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.StateEditKind.commit_clear)), st_searchcommitedit(1, 0).kind);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.StateEditKind.commit_set)), st_searchcommitedit(1, 3).kind);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.StateEditKind.cancel)), st_searchcanceledit(1).kind);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.StateEditKind.clear_input)), st_searchclearinputedit(1).kind);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(search.StateEditKind.none)), st_searchclearinputedit(0).kind);
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

test "search set plan keeps allocation nonzero and resets current" {
    const empty = st_searchsetplan(0, 0);
    const active = st_searchsetplan(6, 2);

    try std.testing.expectEqual(@as(usize, 1), empty.alloc_len);
    try std.testing.expectEqual(@as(c_int, 0), empty.active);
    try std.testing.expectEqual(@as(c_int, 1), active.active);
    try std.testing.expectEqual(@as(c_int, -1), active.current);
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

test "selection normalize keeps regular multiline edge columns" {
    const bounds = st_selnormalizeplan(sel_regular, 7, 4, 2, 9);

    try std.testing.expectEqual(@as(c_int, 7), bounds.nb_x);
    try std.testing.expectEqual(@as(c_int, 4), bounds.nb_y);
    try std.testing.expectEqual(@as(c_int, 2), bounds.ne_x);
    try std.testing.expectEqual(@as(c_int, 9), bounds.ne_y);
}

test "selection normalize sorts same line columns" {
    const bounds = st_selnormalizeplan(sel_regular, 8, 3, 2, 3);

    try std.testing.expectEqual(@as(c_int, 2), bounds.nb_x);
    try std.testing.expectEqual(@as(c_int, 3), bounds.nb_y);
    try std.testing.expectEqual(@as(c_int, 8), bounds.ne_x);
    try std.testing.expectEqual(@as(c_int, 3), bounds.ne_y);
}

test "selection normalize rectangular sorts both axes" {
    const bounds = st_selnormalizeplan(sel_rectangular, 8, 6, 2, 3);

    try std.testing.expectEqual(@as(c_int, 2), bounds.nb_x);
    try std.testing.expectEqual(@as(c_int, 3), bounds.nb_y);
    try std.testing.expectEqual(@as(c_int, 8), bounds.ne_x);
    try std.testing.expectEqual(@as(c_int, 6), bounds.ne_y);
}

test "selection normalize cols adjusts regular edges" {
    const bounds = st_selnormalizecolsplan(sel_regular, 8, 9, 5, 9, 10);

    try std.testing.expectEqual(@as(c_int, 5), bounds.nb_x);
    try std.testing.expectEqual(@as(c_int, 9), bounds.ne_x);
}
