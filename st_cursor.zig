//! st_cursor.zig 负责光标移动 clamp、换行、绘制光标和保存恢复规划。
//! [输入]: 目标坐标、光标状态、滚动区域、dirty/line 指针和保存恢复 mode。
//! [输出]: `ZigCursorMove`、`ZigNewlinePlan`、draw frame/region plan 和 cursor store plan。
//! [副作用边界]: 不调用 `tmoveto(...)` / `tmoveato(...)`，不修改 `term.c`；C 侧 executor 负责真实移动。
//! [定位]: 支撑 C executor 的光标副作用边界；CSI 顶层分类已收敛到 `st_csi.zig`。

const std = @import("std");
const model = @import("term_model.zig");

pub const ZigCursorPlan = extern struct {
    kind: c_int,
    x: c_int,
    y: c_int,
};

pub const ZigCursorMove = extern struct {
    x: c_int,
    y: c_int,
    state: c_int,
};

pub const ZigNewlinePlan = extern struct {
    scroll: c_int,
    scroll_top: c_int,
    x: c_int,
    y: c_int,
};

const ZigGlyph = extern struct {
    u: u32,
    mode: c_ushort,
    fg: u32,
    bg: u32,
};

pub const ZigDrawCursorPlan = extern struct {
    cx: c_int,
    ocx: c_int,
    ocy: c_int,
};

pub const ZigDrawRegionPlan = extern struct {
    draw: c_int,
    y: c_int,
    next_y: c_int,
};

pub const ZigDrawFramePlan = extern struct {
    search_scan: c_int,
    cx: c_int,
    ocx: c_int,
    ocy: c_int,
    cursor_active: c_int,
    imspot_active: c_int,
};

pub const ZigDrawExecPlan = extern struct {
    search_scan: c_int,
    cx: c_int,
    ocx: c_int,
    ocy: c_int,
    cursor_active: c_int,
    imspot_active: c_int,
    region_draw: c_int,
    region_y: c_int,
    region_next_y: c_int,
};

pub const ZigCursorStorePlan = extern struct {
    action: c_int,
    slot: c_int,
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

const CursorMove = struct {
    x: c_int,
    y: c_int,
    state: c_int,
    col: c_int,
    row: c_int,
    top: c_int,
    bot: c_int,

    fn clamp(self: CursorMove) ZigCursorMove {
        const min_y: c_int = if ((self.state & cursor_origin) != 0) self.top else 0;
        const max_y: c_int = if ((self.state & cursor_origin) != 0) self.bot else self.row - 1;

        return .{
            .x = limitInt(self.x, 0, self.col - 1),
            .y = limitInt(self.y, min_y, max_y),
            .state = self.state & ~@as(c_int, cursor_wrapnext),
        };
    }
};

const CursorLine = struct {
    x: c_int,
    y: c_int,
    top: c_int,
    bot: c_int,

    fn newline(self: CursorLine, first_col: bool) ZigNewlinePlan {
        return .{
            .scroll = if (self.y == self.bot) 1 else 0,
            .scroll_top = self.top,
            .x = if (first_col) 0 else self.x,
            .y = if (self.y == self.bot) self.y else self.y + 1,
        };
    }

    fn reverseIndex(self: CursorLine) ZigNewlinePlan {
        return .{
            .scroll = if (self.y == self.top) 1 else 0,
            .scroll_top = self.top,
            .x = self.x,
            .y = if (self.y == self.top) self.y else self.y - 1,
        };
    }
};

const CursorOrigin = struct {
    state: c_int,
    top: c_int,

    fn absoluteY(self: CursorOrigin, y: c_int) c_int {
        return y + if ((self.state & cursor_origin) != 0) self.top else 0;
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
                .ocx = limitInt(self.ocx, 0, self.col - 1),
                .ocy = limitInt(self.ocy, 0, self.row - 1),
            };

            if ((self.lines[@intCast(result.ocy)][@intCast(result.ocx)].mode & attr_wdummy) != 0) {
                result.ocx -= 1;
            }
            if ((self.lines[@intCast(self.current_y)][@intCast(result.cx)].mode & attr_wdummy) != 0) {
                result.cx -= 1;
            }
            return result;
        }
    };
}

const CursorStore = struct {
    mode: c_int,
    alt: bool,

    fn plan(self: CursorStore) ZigCursorStorePlan {
        return .{
            .action = switch (self.mode) {
                cursor_save => cursor_store_save,
                cursor_load => cursor_store_load,
                else => cursor_store_none,
            },
            .slot = if (self.alt) 1 else 0,
        };
    }
};

const DrawRegion = struct {
    dirty: []const c_int,
    start_y: c_int,
    end_y: c_int,

    fn plan(self: DrawRegion) ZigDrawRegionPlan {
        var y = self.start_y;
        while (y < self.end_y) : (y += 1) {
            if (self.dirty[@intCast(y)] != 0) {
                return .{ .draw = 1, .y = y, .next_y = y + 1 };
            }
        }
        return .{ .draw = 0, .y = self.end_y, .next_y = self.end_y };
    }
};

export fn st_tmoveto(x: c_int, y: c_int, state: c_int, col: c_int, row: c_int, top: c_int, bot: c_int) ZigCursorMove {
    return (CursorMove{ .x = x, .y = y, .state = state, .col = col, .row = row, .top = top, .bot = bot }).clamp();
}

export fn st_tnewline(first_col: c_int, x: c_int, y: c_int, top: c_int, bot: c_int) ZigNewlinePlan {
    return (CursorLine{ .x = x, .y = y, .top = top, .bot = bot }).newline(first_col != 0);
}

export fn st_treverseindex(x: c_int, y: c_int, top: c_int) ZigNewlinePlan {
    return (CursorLine{ .x = x, .y = y, .top = top, .bot = top }).reverseIndex();
}

fn drawFramePlan(search_active: c_int, scr: c_int, cx: c_int, current_y: c_int, ocx: c_int, ocy: c_int, col: c_int, row: c_int, lines: [*]const [*]const ZigGlyph) ZigDrawFramePlan {
    const cursor = (DrawCursor(ZigGlyph){ .cx = cx, .current_y = current_y, .ocx = ocx, .ocy = ocy, .col = col, .row = row, .lines = lines[0..@intCast(row)] }).plan();
    return .{
        .search_scan = if (search_active != 0) 1 else 0,
        .cx = cursor.cx,
        .ocx = cursor.ocx,
        .ocy = cursor.ocy,
        .cursor_active = if (scr == 0) 1 else 0,
        .imspot_active = if (ocx != cursor.cx or ocy != current_y) 1 else 0,
    };
}

export fn st_drawexecplan(search_active: c_int, scr: c_int, cx: c_int, current_y: c_int, ocx: c_int, ocy: c_int, col: c_int, row: c_int, lines: [*]const [*]const ZigGlyph, dirty: [*]const c_int, y1: c_int, y2: c_int) ZigDrawExecPlan {
    const frame = drawFramePlan(search_active, scr, cx, current_y, ocx, ocy, col, row, lines);
    const region = (DrawRegion{ .dirty = dirty[0..@intCast(y2)], .start_y = y1, .end_y = y2 }).plan();
    return .{
        .search_scan = frame.search_scan,
        .cx = frame.cx,
        .ocx = frame.ocx,
        .ocy = frame.ocy,
        .cursor_active = frame.cursor_active,
        .imspot_active = frame.imspot_active,
        .region_draw = region.draw,
        .region_y = region.y,
        .region_next_y = region.next_y,
    };
}

export fn st_drawregionplan(dirty: [*]const c_int, y: c_int, y2: c_int) ZigDrawRegionPlan {
    return (DrawRegion{ .dirty = dirty[0..@intCast(y2)], .start_y = y, .end_y = y2 }).plan();
}

export fn st_tcursorplan(mode: c_int, alt: c_int) ZigCursorStorePlan {
    return (CursorStore{ .mode = mode, .alt = alt != 0 }).plan();
}

fn limitInt(value: c_int, lower: c_int, upper: c_int) c_int {
    if (value < lower) return lower;
    if (value > upper) return upper;
    return value;
}

test "tmoveto clears wrapnext and clamps to full screen" {
    const move = st_tmoveto(99, -3, cursor_wrapnext, 10, 6, 2, 4);

    try std.testing.expectEqual(@as(c_int, 9), move.x);
    try std.testing.expectEqual(@as(c_int, 0), move.y);
    try std.testing.expectEqual(@as(c_int, 0), move.state);
}

test "tmoveto origin mode clamps to scroll region" {
    const move = st_tmoveto(4, 9, cursor_origin | cursor_wrapnext, 10, 6, 2, 4);

    try std.testing.expectEqual(@as(c_int, 4), move.x);
    try std.testing.expectEqual(@as(c_int, 4), move.y);
    try std.testing.expectEqual(@as(c_int, cursor_origin), move.state);
}

test "tnewline advances within scroll region" {
    const plan = st_tnewline(0, 5, 3, 1, 6);

    try std.testing.expectEqual(@as(c_int, 0), plan.scroll);
    try std.testing.expectEqual(@as(c_int, 5), plan.x);
    try std.testing.expectEqual(@as(c_int, 4), plan.y);
}

test "tnewline scrolls at bottom and honors first column" {
    const plan = st_tnewline(1, 5, 6, 1, 6);

    try std.testing.expectEqual(@as(c_int, 1), plan.scroll);
    try std.testing.expectEqual(@as(c_int, 1), plan.scroll_top);
    try std.testing.expectEqual(@as(c_int, 0), plan.x);
    try std.testing.expectEqual(@as(c_int, 6), plan.y);
}

test "treverseindex scrolls at top otherwise moves up" {
    const scroll = st_treverseindex(5, 2, 2);
    const move = st_treverseindex(5, 4, 2);

    try std.testing.expectEqual(@as(c_int, 1), scroll.scroll);
    try std.testing.expectEqual(@as(c_int, 2), scroll.y);
    try std.testing.expectEqual(@as(c_int, 0), move.scroll);
    try std.testing.expectEqual(@as(c_int, 3), move.y);
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
    const plan = drawFramePlan(1, 0, 1, 1, 9, 0, 2, 2, &lines);

    try std.testing.expectEqual(@as(c_int, 1), plan.search_scan);
    try std.testing.expectEqual(@as(c_int, 0), plan.cx);
    try std.testing.expectEqual(@as(c_int, 0), plan.ocx);
    try std.testing.expectEqual(@as(c_int, 0), plan.ocy);
    try std.testing.expectEqual(@as(c_int, 1), plan.cursor_active);
    try std.testing.expectEqual(@as(c_int, 1), plan.imspot_active);
}

test "draw region plan finds next dirty line" {
    const dirty = [_]c_int{ 0, 0, 3, 0 };
    const found = st_drawregionplan(&dirty, 0, dirty.len);
    const empty = st_drawregionplan(&dirty, 3, dirty.len);

    try std.testing.expectEqual(@as(c_int, 1), found.draw);
    try std.testing.expectEqual(@as(c_int, 2), found.y);
    try std.testing.expectEqual(@as(c_int, 3), found.next_y);
    try std.testing.expectEqual(@as(c_int, 0), empty.draw);
    try std.testing.expectEqual(@as(c_int, 4), empty.next_y);
}

test "draw exec plan combines frame and first dirty region" {
    var row0 = [_]ZigGlyph{.{ .u = '甲', .mode = 0, .fg = 0, .bg = 0 }};
    var row1 = [_]ZigGlyph{.{ .u = '乙', .mode = 0, .fg = 0, .bg = 0 }};
    const lines = [_][*]const ZigGlyph{ &row0, &row1 };
    const dirty = [_]c_int{ 0, 1 };
    const plan = st_drawexecplan(1, 0, 0, 0, 0, 0, 1, 2, &lines, &dirty, 0, dirty.len);

    try std.testing.expectEqual(@as(c_int, 1), plan.search_scan);
    try std.testing.expectEqual(@as(c_int, 1), plan.cursor_active);
    try std.testing.expectEqual(@as(c_int, 1), plan.region_draw);
    try std.testing.expectEqual(@as(c_int, 1), plan.region_y);
    try std.testing.expectEqual(@as(c_int, 2), plan.region_next_y);
}

test "draw plans gate search scan and cursor" {
    var row0 = [_]ZigGlyph{.{ .u = 'a', .mode = 0, .fg = 0, .bg = 0 }};
    const lines = [_][*]const ZigGlyph{&row0};
    const inactive = drawFramePlan(0, 2, 0, 0, 0, 0, 1, 1, &lines);

    try std.testing.expectEqual(@as(c_int, 0), inactive.search_scan);
    try std.testing.expectEqual(@as(c_int, 0), inactive.cursor_active);
    try std.testing.expectEqual(@as(c_int, 0), inactive.imspot_active);
}

test "tcursor plan maps mode and alt slot" {
    const save = st_tcursorplan(cursor_save, 1);
    const load = st_tcursorplan(cursor_load, 0);

    try std.testing.expectEqual(@as(c_int, cursor_store_save), save.action);
    try std.testing.expectEqual(@as(c_int, 1), save.slot);
    try std.testing.expectEqual(@as(c_int, cursor_store_load), load.action);
    try std.testing.expectEqual(@as(c_int, 0), load.slot);
}
