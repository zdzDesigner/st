//! st_cursor.zig 负责光标移动 clamp、换行、绘制光标和保存恢复规划。
//! [输入]: 目标坐标、光标状态、滚动区域、dirty/line 指针和保存恢复 mode。
//! [输出]: `ZigTermCursorPlan`、term frame snapshot 和 draw frame/region plan。
//! [副作用边界]: 不调用 `tmoveto(...)` / `tmoveato(...)`，不修改 `term.c`；C 侧 executor 负责真实移动。
//! [定位]: 支撑 C executor 的光标副作用边界；CSI 顶层分类已收敛到 `st_csi.zig`。

const std = @import("std");
const model = @import("term_model.zig");
const platform = @import("st_platform.zig");

const ZigPlatformEffect = platform.ZigPlatformEffect;
const ZigPlatformEffectList = platform.ZigPlatformEffectList;

pub const ZigCursorPlan = extern struct {
    kind: c_int,
    x: c_int,
    y: c_int,
};

pub const ZigTermCursorSnapshot = extern struct {
    state: c_int,
    x: c_int,
    y: c_int,
    col: c_int,
    row: c_int,
    top: c_int,
    bot: c_int,
};

pub const ZigTermCursorPlan = extern struct {
    action: c_int,
    x: c_int,
    y: c_int,
    state: c_int,
    scroll: c_int,
    scroll_down: c_int,
    scroll_top: c_int,
    slot: c_int,
};

pub const ZigBackspacePlan = extern struct {
    x: c_int,
    y: c_int,
    state: c_int,
    dirty: c_int,
    dirty_top: c_int,
    dirty_bot: c_int,
};

const ZigGlyph = extern struct {
    u: u32,
    mode: c_ushort,
    fg: u32,
    bg: u32,
};

pub const ZigDrawCursorPlan = extern struct {
    cx: c_int,
    cy: c_int,
    ocx: c_int,
    ocy: c_int,
};

pub const ZigTermFrameSnapshot = extern struct {
    search_active: c_int,
    scr: c_int,
    cx: c_int,
    current_y: c_int,
    ocx: c_int,
    ocy: c_int,
    col: c_int,
    row: c_int,
};

pub const ZigDrawFramePlan = extern struct {
    search_scan: c_int,
    cx: c_int,
    cy: c_int,
    ocx: c_int,
    ocy: c_int,
    cursor_active: c_int,
    imspot_active: c_int,
};

pub const ZigDrawExecPlan = extern struct {
    cx: c_int,
    cy: c_int,
    ocx: c_int,
    ocy: c_int,
    new_ocx: c_int,
    new_ocy: c_int,
    platform: ZigPlatformEffectList,
};

const DrawRegionPlan = struct {
    draw: c_int,
    y: c_int,
    next_y: c_int,
};

pub const ZigDrawRegionPlan = extern struct {
    draw: c_int,
    y: c_int,
    next_y: c_int,
};

pub const ZigDrawRegionTransaction = extern struct {
    step_count: c_int,
    steps: [2048]ZigPlatformEffect,
};

pub const cursor_move_to = 0;
pub const cursor_move_to_abs = 1;
pub const cursor_unknown = 2;

const cursor_wrapnext = 1;
const cursor_origin = 2;
const cursor_save = 0;
const cursor_load = 1;
const cursor_store_none = 0;
const cursor_store_save = 1;
const cursor_store_load = 2;
const attr_wdummy = model.attr_wdummy;
const term_cursor_move_to: c_int = 0;
const term_cursor_move_to_abs: c_int = 1;
const term_cursor_newline: c_int = 2;
const term_cursor_reverse_index: c_int = 3;
const term_cursor_store: c_int = 4;
const platform_effect_search_scan = platform.effect_search_scan;
const platform_effect_draw_region = platform.effect_draw_region;
const platform_effect_draw_cursor = platform.effect_draw_cursor;
const platform_effect_finish_draw = platform.effect_finish_draw;
const platform_effect_ime_spot = platform.effect_ime_spot;
const platform_effect_region_clear_dirty = platform.effect_region_clear_dirty;
const platform_effect_region_draw_line = platform.effect_region_draw_line;
const platform_effect_region_advance = platform.effect_region_advance;

const TermCursor = struct {
    state: c_int,
    x: c_int,
    y: c_int,
    col: c_int,
    row: c_int,
    top: c_int,
    bot: c_int,

    fn fromSnapshot(snapshot: ZigTermCursorSnapshot) TermCursor {
        return .{
            .state = snapshot.state,
            .x = snapshot.x,
            .y = snapshot.y,
            .col = snapshot.col,
            .row = snapshot.row,
            .top = snapshot.top,
            .bot = snapshot.bot,
        };
    }

    fn moveTo(self: TermCursor, action: c_int, x: c_int, y: c_int) ZigTermCursorPlan {
        const min_y: c_int = if ((self.state & cursor_origin) != 0) self.top else 0;
        const max_y: c_int = if ((self.state & cursor_origin) != 0) self.bot else self.row - 1;

        return .{
            .action = action,
            .x = limitInt(x, 0, self.col - 1),
            .y = limitInt(y, min_y, max_y),
            .state = self.state & ~@as(c_int, cursor_wrapnext),
            .scroll = 0,
            .scroll_down = 0,
            .scroll_top = 0,
            .slot = 0,
        };
    }

    fn moveToAbs(self: TermCursor, x: c_int, y: c_int) ZigTermCursorPlan {
        const absolute_y = y + if ((self.state & cursor_origin) != 0) self.top else 0;
        return self.moveTo(term_cursor_move_to_abs, x, absolute_y);
    }

    fn newline(self: TermCursor, first_col: bool) ZigTermCursorPlan {
        const y = if (self.y == self.bot) self.y else self.y + 1;
        return .{
            .action = term_cursor_newline,
            .x = limitInt(if (first_col) 0 else self.x, 0, self.col - 1),
            .y = limitInt(y, 0, self.row - 1),
            .state = self.state & ~@as(c_int, cursor_wrapnext),
            .scroll = if (self.y == self.bot) 1 else 0,
            .scroll_down = 0,
            .scroll_top = self.top,
            .slot = 0,
        };
    }

    fn reverseIndex(self: TermCursor) ZigTermCursorPlan {
        const y = if (self.y == self.top) self.y else self.y - 1;
        return .{
            .action = term_cursor_reverse_index,
            .x = limitInt(self.x, 0, self.col - 1),
            .y = limitInt(y, 0, self.row - 1),
            .state = self.state & ~@as(c_int, cursor_wrapnext),
            .scroll = if (self.y == self.top) 1 else 0,
            .scroll_down = 1,
            .scroll_top = self.top,
            .slot = 0,
        };
    }

    fn backspace(self: TermCursor) ZigBackspacePlan {
        const next_state = self.state & ~@as(c_int, cursor_wrapnext);

        if (self.x > 0) {
            return .{ .x = self.x - 1, .y = self.y, .state = next_state, .dirty = 0, .dirty_top = 0, .dirty_bot = 0 };
        }

        return .{ .x = self.x, .y = self.y, .state = next_state, .dirty = 0, .dirty_top = 0, .dirty_bot = 0 };
    }
};

fn DrawCursor(comptime Glyph: type) type {
    return struct {
        cx: c_int,
        current_y: c_int,
        ocx: c_int,
        ocy: c_int,
        col: c_int,
        row: c_int,
        lines: []const [*]const Glyph,

        const Self = @This();

        fn plan(self: Self) ZigDrawCursorPlan {
            var result = ZigDrawCursorPlan{
                .cx = self.cx,
                .cy = limitInt(self.current_y, 0, self.row - 1),
                .ocx = limitInt(self.ocx, 0, self.col - 1),
                .ocy = limitInt(self.ocy, 0, self.row - 1),
            };

            if ((self.lines[@intCast(result.ocy)][@intCast(result.ocx)].mode & attr_wdummy) != 0) {
                result.ocx -= 1;
            }
            if ((self.lines[@intCast(result.cy)][@intCast(result.cx)].mode & attr_wdummy) != 0) {
                result.cx -= 1;
            }
            return result;
        }
    };
}

const DrawRegion = struct {
    dirty: []const c_int,
    start_y: c_int,
    end_y: c_int,

    fn plan(self: DrawRegion) DrawRegionPlan {
        var y = self.start_y;
        while (y < self.end_y) : (y += 1) {
            if (self.dirty[@intCast(y)] != 0) {
                return .{ .draw = 1, .y = y, .next_y = y + 1 };
            }
        }
        return .{ .draw = 0, .y = self.end_y, .next_y = self.end_y };
    }

    fn transaction(self: DrawRegion) ZigDrawRegionTransaction {
        var tx = ZigDrawRegionTransaction{ .step_count = 0, .steps = std.mem.zeroes([2048]ZigPlatformEffect) };
        var y = self.start_y;
        while (y < self.end_y) : (y += 1) {
            if (self.dirty[@intCast(y)] == 0) continue;
            addDrawRegionStep(&tx, platform_effect_region_draw_line, y, y + 1);
            addDrawRegionStep(&tx, platform_effect_region_clear_dirty, y, y + 1);
            addDrawRegionStep(&tx, platform_effect_region_advance, y, y + 1);
        }
        return tx;
    }
};

fn addDrawRegionStep(tx: *ZigDrawRegionTransaction, kind: c_int, y: c_int, next_y: c_int) void {
    if (@as(usize, @intCast(tx.step_count)) >= tx.steps.len) return;
    tx.steps[@intCast(tx.step_count)] = .{ .kind = kind, .arg = y, .index_arg = next_y };
    tx.step_count += 1;
}

fn emptyPlatformEffects() ZigPlatformEffectList {
    return platform.emptyEffects();
}

fn addPlatformEffect(list: *ZigPlatformEffectList, kind: c_int, arg: c_int, index_arg: c_int) void {
    platform.addEffect(list, kind, arg, index_arg);
}

export fn st_termcursorplan(action: c_int, snapshot: ZigTermCursorSnapshot, arg_x: c_int, arg_y: c_int) ZigTermCursorPlan {
    const cursor = TermCursor.fromSnapshot(snapshot);
    return switch (action) {
        term_cursor_move_to => cursor.moveTo(term_cursor_move_to, arg_x, arg_y),
        term_cursor_move_to_abs => cursor.moveToAbs(arg_x, arg_y),
        term_cursor_newline => cursor.newline(arg_x != 0),
        term_cursor_reverse_index => cursor.reverseIndex(),
        term_cursor_store => .{
            .action = switch (arg_x) {
                cursor_save => cursor_store_save,
                cursor_load => cursor_store_load,
                else => cursor_store_none,
            },
            .x = snapshot.x,
            .y = snapshot.y,
            .state = snapshot.state,
            .scroll = 0,
            .scroll_down = 0,
            .scroll_top = 0,
            .slot = if (arg_y != 0) 1 else 0,
        },
        else => cursor.moveTo(term_cursor_move_to, snapshot.x, snapshot.y),
    };
}

export fn st_backspaceplan(snapshot: ZigTermCursorSnapshot) ZigBackspacePlan {
    return TermCursor.fromSnapshot(snapshot).backspace();
}

fn drawFramePlan(snapshot: ZigTermFrameSnapshot, lines: [*]const [*]const ZigGlyph) ZigDrawFramePlan {
    const cursor = (DrawCursor(ZigGlyph){ .cx = snapshot.cx, .current_y = snapshot.current_y, .ocx = snapshot.ocx, .ocy = snapshot.ocy, .col = snapshot.col, .row = snapshot.row, .lines = lines[0..@intCast(snapshot.row)] }).plan();
    return .{
        .search_scan = if (snapshot.search_active != 0) 1 else 0,
        .cx = cursor.cx,
        .cy = cursor.cy,
        .ocx = cursor.ocx,
        .ocy = cursor.ocy,
        .cursor_active = if (snapshot.scr == 0) 1 else 0,
        .imspot_active = if (snapshot.ocx != cursor.cx or snapshot.ocy != snapshot.current_y) 1 else 0,
    };
}

export fn st_drawexecplan(snapshot: ZigTermFrameSnapshot, lines: [*]const [*]const ZigGlyph, dirty: [*]const c_int, y1: c_int, y2: c_int) ZigDrawExecPlan {
    const frame = drawFramePlan(snapshot, lines);
    const region = (DrawRegion{ .dirty = dirty[0..@intCast(y2)], .start_y = y1, .end_y = y2 }).plan();
    var effects = emptyPlatformEffects();
    if (frame.search_scan != 0) addPlatformEffect(&effects, platform_effect_search_scan, 0, 0);
    if (region.draw != 0) addPlatformEffect(&effects, platform_effect_draw_region, region.y, 0);
    if (frame.cursor_active != 0) addPlatformEffect(&effects, platform_effect_draw_cursor, frame.cx, 0);
    addPlatformEffect(&effects, platform_effect_finish_draw, 0, 0);
    if (frame.imspot_active != 0) addPlatformEffect(&effects, platform_effect_ime_spot, frame.cx, frame.cy);
    return .{
        .cx = frame.cx,
        .cy = frame.cy,
        .ocx = frame.ocx,
        .ocy = frame.ocy,
        .new_ocx = frame.cx,
        .new_ocy = frame.cy,
        .platform = effects,
    };
}

fn st_drawregionnext(dirty: [*]const c_int, y1: c_int, y2: c_int) DrawRegionPlan {
    return (DrawRegion{ .dirty = dirty[0..@intCast(y2)], .start_y = y1, .end_y = y2 }).plan();
}

export fn st_drawregionplan(dirty: [*]const c_int, y1: c_int, y2: c_int) ZigDrawRegionPlan {
    const plan = st_drawregionnext(dirty, y1, y2);
    return .{ .draw = plan.draw, .y = plan.y, .next_y = plan.next_y };
}

fn st_drawregiontransaction(dirty: [*]const c_int, y1: c_int, y2: c_int) ZigDrawRegionTransaction {
    return (DrawRegion{ .dirty = dirty[0..@intCast(y2)], .start_y = y1, .end_y = y2 }).transaction();
}

fn limitInt(value: c_int, lower: c_int, upper: c_int) c_int {
    if (value < lower) return lower;
    if (value > upper) return upper;
    return value;
}

test "termcursorplan move clears wrapnext and clamps to full screen" {
    const snapshot = ZigTermCursorSnapshot{ .state = cursor_wrapnext, .x = 0, .y = 0, .col = 10, .row = 6, .top = 2, .bot = 4 };
    const move = st_termcursorplan(term_cursor_move_to, snapshot, 99, -3);

    try std.testing.expectEqual(@as(c_int, term_cursor_move_to), move.action);
    try std.testing.expectEqual(@as(c_int, 9), move.x);
    try std.testing.expectEqual(@as(c_int, 0), move.y);
    try std.testing.expectEqual(@as(c_int, 0), move.state);
    try std.testing.expectEqual(@as(c_int, 0), move.scroll);
}

test "termcursorplan move origin mode clamps to scroll region" {
    const snapshot = ZigTermCursorSnapshot{ .state = cursor_origin | cursor_wrapnext, .x = 0, .y = 0, .col = 10, .row = 6, .top = 2, .bot = 4 };
    const move = st_termcursorplan(term_cursor_move_to, snapshot, 4, 9);

    try std.testing.expectEqual(@as(c_int, 4), move.x);
    try std.testing.expectEqual(@as(c_int, 4), move.y);
    try std.testing.expectEqual(@as(c_int, cursor_origin), move.state);
}

test "termcursorplan absolute move offsets only in origin mode" {
    const normal = ZigTermCursorSnapshot{ .state = 0, .x = 0, .y = 0, .col = 10, .row = 8, .top = 2, .bot = 6 };
    const origin = ZigTermCursorSnapshot{ .state = cursor_origin, .x = 0, .y = 0, .col = 10, .row = 8, .top = 2, .bot = 6 };

    try std.testing.expectEqual(@as(c_int, 4), st_termcursorplan(term_cursor_move_to_abs, normal, 4, 4).y);
    try std.testing.expectEqual(@as(c_int, 6), st_termcursorplan(term_cursor_move_to_abs, origin, 4, 4).y);
}

test "tnewline advances within scroll region" {
    const snapshot = ZigTermCursorSnapshot{ .state = cursor_wrapnext, .x = 5, .y = 3, .col = 10, .row = 8, .top = 1, .bot = 6 };
    const plan = st_termcursorplan(term_cursor_newline, snapshot, 0, 0);

    try std.testing.expectEqual(@as(c_int, 0), plan.scroll);
    try std.testing.expectEqual(@as(c_int, 5), plan.x);
    try std.testing.expectEqual(@as(c_int, 4), plan.y);
    try std.testing.expectEqual(@as(c_int, 0), plan.state);
}

test "tnewline scrolls at bottom and honors first column" {
    const snapshot = ZigTermCursorSnapshot{ .state = 0, .x = 5, .y = 6, .col = 10, .row = 8, .top = 1, .bot = 6 };
    const plan = st_termcursorplan(term_cursor_newline, snapshot, 1, 0);

    try std.testing.expectEqual(@as(c_int, 1), plan.scroll);
    try std.testing.expectEqual(@as(c_int, 1), plan.scroll_top);
    try std.testing.expectEqual(@as(c_int, 0), plan.x);
    try std.testing.expectEqual(@as(c_int, 6), plan.y);
}

test "treverseindex scrolls at top otherwise moves up" {
    const top = ZigTermCursorSnapshot{ .state = 0, .x = 5, .y = 2, .col = 10, .row = 8, .top = 2, .bot = 6 };
    const mid = ZigTermCursorSnapshot{ .state = 0, .x = 5, .y = 4, .col = 10, .row = 8, .top = 2, .bot = 6 };
    const scroll = st_termcursorplan(term_cursor_reverse_index, top, 0, 0);
    const move = st_termcursorplan(term_cursor_reverse_index, mid, 0, 0);

    try std.testing.expectEqual(@as(c_int, 1), scroll.scroll);
    try std.testing.expectEqual(@as(c_int, 1), scroll.scroll_down);
    try std.testing.expectEqual(@as(c_int, 2), scroll.y);
    try std.testing.expectEqual(@as(c_int, 0), move.scroll);
    try std.testing.expectEqual(@as(c_int, 3), move.y);
}

test "backspace with wrapnext still moves left" {
    const snapshot = ZigTermCursorSnapshot{ .state = cursor_wrapnext, .x = 9, .y = 2, .col = 10, .row = 6, .top = 0, .bot = 5 };
    const plan = st_backspaceplan(snapshot);

    try std.testing.expectEqual(@as(c_int, 8), plan.x);
    try std.testing.expectEqual(@as(c_int, 2), plan.y);
    try std.testing.expectEqual(@as(c_int, 0), plan.state);
    try std.testing.expectEqual(@as(c_int, 0), plan.dirty);
}

test "backspace moves left on same row" {
    const snapshot = ZigTermCursorSnapshot{ .state = 0, .x = 4, .y = 2, .col = 10, .row = 6, .top = 0, .bot = 5 };
    const plan = st_backspaceplan(snapshot);

    try std.testing.expectEqual(@as(c_int, 3), plan.x);
    try std.testing.expectEqual(@as(c_int, 2), plan.y);
    try std.testing.expectEqual(@as(c_int, 0), plan.dirty);
}

test "backspace at first column does not cross soft wrapped row" {
    const snapshot = ZigTermCursorSnapshot{ .state = 0, .x = 0, .y = 3, .col = 10, .row = 6, .top = 0, .bot = 5 };
    const plan = st_backspaceplan(snapshot);

    try std.testing.expectEqual(@as(c_int, 0), plan.x);
    try std.testing.expectEqual(@as(c_int, 3), plan.y);
    try std.testing.expectEqual(@as(c_int, 0), plan.dirty);
}

test "backspace at first column without wrap is no-op" {
    const snapshot = ZigTermCursorSnapshot{ .state = 0, .x = 0, .y = 3, .col = 10, .row = 6, .top = 0, .bot = 5 };
    const plan = st_backspaceplan(snapshot);

    try std.testing.expectEqual(@as(c_int, 0), plan.x);
    try std.testing.expectEqual(@as(c_int, 3), plan.y);
    try std.testing.expectEqual(@as(c_int, 0), plan.dirty);
}

test "draw cursor plan clamps old cursor and adjusts dummy cells" {
    var row0 = [_]ZigGlyph{
        .{ .u = '中', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '文', .mode = attr_wdummy, .fg = 0, .bg = 0 },
    };
    var row1 = [_]ZigGlyph{
        .{ .u = '测', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '试', .mode = attr_wdummy, .fg = 0, .bg = 0 },
    };
    const lines = [_][*]const ZigGlyph{ &row0, &row1 };
    const snapshot = ZigTermFrameSnapshot{ .search_active = 1, .scr = 0, .cx = 1, .current_y = 1, .ocx = 9, .ocy = 0, .col = 2, .row = 2 };
    const plan = drawFramePlan(snapshot, &lines);

    try std.testing.expectEqual(@as(c_int, 1), plan.search_scan);
    try std.testing.expectEqual(@as(c_int, 0), plan.cx);
    try std.testing.expectEqual(@as(c_int, 1), plan.cy);
    try std.testing.expectEqual(@as(c_int, 0), plan.ocx);
    try std.testing.expectEqual(@as(c_int, 0), plan.ocy);
    try std.testing.expectEqual(@as(c_int, 1), plan.cursor_active);
    try std.testing.expectEqual(@as(c_int, 1), plan.imspot_active);
}

test "draw region plan finds next dirty line" {
    const dirty = [_]c_int{ 0, 0, 3, 0 };
    const row0 = [_]ZigGlyph{.{ .u = '甲', .mode = 0, .fg = 0, .bg = 0 }};
    const lines = [_][*]const ZigGlyph{ &row0, &row0, &row0, &row0 };
    const snapshot = ZigTermFrameSnapshot{ .search_active = 0, .scr = 1, .cx = 0, .current_y = 0, .ocx = 0, .ocy = 0, .col = 1, .row = 4 };
    const found = st_drawexecplan(snapshot, &lines, &dirty, 0, dirty.len);
    const empty = st_drawexecplan(snapshot, &lines, &dirty, 3, dirty.len);

    try std.testing.expectEqual(@as(c_int, 2), found.platform.effects[0].arg);
    try std.testing.expectEqual(@as(c_int, 1), empty.platform.count);
    try std.testing.expectEqual(@as(c_int, platform_effect_finish_draw), empty.platform.effects[0].kind);
}

test "draw region next returns clear then draw ordering" {
    const dirty = [_]c_int{ 0, 1, 0 };
    const region = st_drawregionnext(&dirty, 0, dirty.len);

    try std.testing.expectEqual(@as(c_int, 1), region.draw);
    try std.testing.expectEqual(@as(c_int, 1), region.y);
    try std.testing.expectEqual(@as(c_int, 2), region.next_y);
}

test "draw region transaction consumes all dirty rows" {
    const dirty = [_]c_int{ 1, 0, 1, 1 };
    const tx = st_drawregiontransaction(&dirty, 0, dirty.len);

    try std.testing.expectEqual(@as(c_int, 9), tx.step_count);
    try std.testing.expectEqual(@as(c_int, platform_effect_region_draw_line), tx.steps[0].kind);
    try std.testing.expectEqual(@as(c_int, 0), tx.steps[0].arg);
    try std.testing.expectEqual(@as(c_int, platform_effect_region_clear_dirty), tx.steps[1].kind);
    try std.testing.expectEqual(@as(c_int, 2), tx.steps[3].arg);
    try std.testing.expectEqual(@as(c_int, 3), tx.steps[6].arg);
}

test "draw exec plan combines frame and first dirty region" {
    var row0 = [_]ZigGlyph{.{ .u = '甲', .mode = 0, .fg = 0, .bg = 0 }};
    var row1 = [_]ZigGlyph{.{ .u = '乙', .mode = 0, .fg = 0, .bg = 0 }};
    const lines = [_][*]const ZigGlyph{ &row0, &row1 };
    const dirty = [_]c_int{ 0, 1 };
    const snapshot = ZigTermFrameSnapshot{ .search_active = 1, .scr = 0, .cx = 0, .current_y = 0, .ocx = 0, .ocy = 0, .col = 1, .row = 2 };
    const plan = st_drawexecplan(snapshot, &lines, &dirty, 0, dirty.len);

    try std.testing.expectEqual(@as(c_int, 0), plan.new_ocx);
    try std.testing.expectEqual(@as(c_int, 0), plan.new_ocy);
    try std.testing.expectEqual(@as(c_int, 0), plan.cy);
    try std.testing.expectEqual(@as(c_int, 4), plan.platform.count);
    try std.testing.expectEqual(@as(c_int, platform_effect_search_scan), plan.platform.effects[0].kind);
    try std.testing.expectEqual(@as(c_int, platform_effect_draw_region), plan.platform.effects[1].kind);
    try std.testing.expectEqual(@as(c_int, platform_effect_draw_cursor), plan.platform.effects[2].kind);
    try std.testing.expectEqual(@as(c_int, platform_effect_finish_draw), plan.platform.effects[3].kind);
}

test "draw exec plan returns post draw cursor state without dirty region" {
    var row0 = [_]ZigGlyph{.{ .u = '甲', .mode = 0, .fg = 0, .bg = 0 }};
    var row1 = [_]ZigGlyph{.{ .u = '乙', .mode = 0, .fg = 0, .bg = 0 }};
    const lines = [_][*]const ZigGlyph{ &row0, &row1 };
    const dirty = [_]c_int{ 0, 0 };
    const snapshot = ZigTermFrameSnapshot{ .search_active = 0, .scr = 0, .cx = 0, .current_y = 1, .ocx = 0, .ocy = 0, .col = 1, .row = 2 };
    const plan = st_drawexecplan(snapshot, &lines, &dirty, 0, dirty.len);

    try std.testing.expectEqual(@as(c_int, 3), plan.platform.count);
    try std.testing.expectEqual(@as(c_int, 0), plan.new_ocx);
    try std.testing.expectEqual(@as(c_int, 1), plan.new_ocy);
}

test "draw plans gate search scan and cursor" {
    var row0 = [_]ZigGlyph{.{ .u = 'a', .mode = 0, .fg = 0, .bg = 0 }};
    const lines = [_][*]const ZigGlyph{&row0};
    const snapshot = ZigTermFrameSnapshot{ .search_active = 0, .scr = 2, .cx = 0, .current_y = 0, .ocx = 0, .ocy = 0, .col = 1, .row = 1 };
    const inactive = drawFramePlan(snapshot, &lines);

    try std.testing.expectEqual(@as(c_int, 0), inactive.search_scan);
    try std.testing.expectEqual(@as(c_int, 0), inactive.cursor_active);
    try std.testing.expectEqual(@as(c_int, 0), inactive.imspot_active);
}

test "tcursor plan maps mode and alt slot" {
    const snapshot = ZigTermCursorSnapshot{ .state = 0, .x = 0, .y = 0, .col = 10, .row = 8, .top = 1, .bot = 6 };
    const save = st_termcursorplan(term_cursor_store, snapshot, cursor_save, 1);
    const load = st_termcursorplan(term_cursor_store, snapshot, cursor_load, 0);

    try std.testing.expectEqual(@as(c_int, cursor_store_save), save.action);
    try std.testing.expectEqual(@as(c_int, 1), save.slot);
    try std.testing.expectEqual(@as(c_int, cursor_store_load), load.action);
    try std.testing.expectEqual(@as(c_int, 0), load.slot);
}
