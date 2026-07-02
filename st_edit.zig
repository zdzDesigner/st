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
    hist_swap: c_int,
    hist_line: c_int,
    line_start: c_int,
    line_end: c_int,
    line_step: c_int,
    line_offset: c_int,
    selscroll_delta: c_int,
    clear_x1: c_int,
    clear_y1: c_int,
    clear_x2: c_int,
    clear_y2: c_int,
    dirty_top: c_int,
    dirty_bot: c_int,
    step_count: c_int,
    steps: [6]ZigScrollStep,
};

pub const ZigScrollStep = extern struct {
    kind: c_int,
    a: c_int,
    b: c_int,
    c: c_int,
    d: c_int,
};

pub const ZigKScrollPlan = extern struct {
    run: c_int,
    new_scr: c_int,
    delta: c_int,
    selscroll_delta: c_int,
    full_dirty: c_int,
};

pub const edit_insert_blank = 0;
pub const edit_scroll_up = 1;
pub const edit_scroll_down = 2;
pub const edit_insert_blank_line = 3;
pub const edit_delete_line = 4;
pub const edit_clear_region = 5;
pub const edit_delete_char = 6;
pub const edit_unknown = 7;
pub const scroll_step_hist_swap = 1;
pub const scroll_step_scr_update = 2;
pub const scroll_step_clear_rect = 3;
pub const scroll_step_dirty_range = 4;
pub const scroll_step_line_swap_loop = 5;
pub const scroll_step_selection_scroll = 6;

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
        var plan = ZigScrollPlan{
            .count = count,
            .new_scr = new_scr,
            .new_histi = new_histi,
            .hist_swap = if (copyhist and histsize > 0) 1 else 0,
            .hist_line = if (scroll_up) self.top else self.bot,
            .line_start = if (scroll_up) self.top else self.bot,
            .line_end = if (scroll_up) self.bot - count else self.top + count,
            .line_step = if (scroll_up) 1 else -1,
            .line_offset = if (scroll_up) count else -count,
            .selscroll_delta = if (scr == 0) (if (scroll_up) -count else count) else 0,
            .clear_x1 = 0,
            .clear_y1 = if (scroll_up) self.top else self.bot - count + 1,
            .clear_x2 = -1,
            .clear_y2 = if (scroll_up) self.top + count - 1 else self.bot,
            .dirty_top = if (scroll_up) self.top + count else self.top,
            .dirty_bot = if (scroll_up) self.bot else self.bot - count,
            .step_count = 0,
            .steps = std.mem.zeroes([6]ZigScrollStep),
        };
        if (plan.hist_swap != 0) addScrollStep(&plan, scroll_step_hist_swap, plan.new_histi, plan.hist_line, 0, 0);
        if (scroll_up) addScrollStep(&plan, scroll_step_scr_update, plan.new_scr, 0, 0, 0);
        if (scroll_up) {
            addScrollStep(&plan, scroll_step_clear_rect, plan.clear_x1, plan.clear_y1, plan.clear_x2, plan.clear_y2);
            addScrollStep(&plan, scroll_step_dirty_range, plan.dirty_top, plan.dirty_bot, 0, 0);
        } else {
            addScrollStep(&plan, scroll_step_dirty_range, plan.dirty_top, plan.dirty_bot, 0, 0);
            addScrollStep(&plan, scroll_step_clear_rect, plan.clear_x1, plan.clear_y1, plan.clear_x2, plan.clear_y2);
        }
        addScrollStep(&plan, scroll_step_line_swap_loop, plan.line_start, plan.line_end, plan.line_step, plan.line_offset);
        if (plan.selscroll_delta != 0) addScrollStep(&plan, scroll_step_selection_scroll, plan.selscroll_delta, 0, 0, 0);
        return plan;
    }
};

fn addScrollStep(plan: *ZigScrollPlan, kind: c_int, a: c_int, b: c_int, c: c_int, d: c_int) void {
    if (@as(usize, @intCast(plan.step_count)) >= plan.steps.len) return;
    plan.steps[@intCast(plan.step_count)] = .{ .kind = kind, .a = a, .b = b, .c = c, .d = d };
    plan.step_count += 1;
}

const KeyboardScroll = struct {
    n: c_int,
    row: c_int,
    scr: c_int,
    histsize: c_int,

    fn down(self: KeyboardScroll) ZigKScrollPlan {
        var count = if (self.n < 0) self.row + self.n else self.n;
        if (count > self.scr) count = self.scr;
        return if (self.scr > 0)
            .{ .run = 1, .new_scr = self.scr - count, .delta = -count, .selscroll_delta = -count, .full_dirty = 1 }
        else
            .{ .run = 0, .new_scr = self.scr, .delta = 0, .selscroll_delta = 0, .full_dirty = 0 };
    }

    fn up(self: KeyboardScroll) ZigKScrollPlan {
        const count = if (self.n < 0) self.row + self.n else self.n;
        return if (self.scr <= self.histsize - count)
            .{ .run = 1, .new_scr = self.scr + count, .delta = count, .selscroll_delta = count, .full_dirty = 1 }
        else
            .{ .run = 0, .new_scr = self.scr, .delta = 0, .selscroll_delta = 0, .full_dirty = 0 };
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
    try std.testing.expectEqual(@as(c_int, 0), plan.hist_swap);
}

test "scroll up plan advances scrollback view" {
    const plan = st_tscrollplan(5, 0, 9, 98, 100, 1, 1, 99);

    try std.testing.expectEqual(@as(c_int, 5), plan.count);
    try std.testing.expectEqual(@as(c_int, 99), plan.new_scr);
    try std.testing.expectEqual(@as(c_int, 0), plan.new_histi);
    try std.testing.expectEqual(@as(c_int, 1), plan.hist_swap);
    try std.testing.expectEqual(@as(c_int, 0), plan.hist_line);
    try std.testing.expectEqual(@as(c_int, 0), plan.line_start);
    try std.testing.expectEqual(@as(c_int, 4), plan.line_end);
    try std.testing.expectEqual(@as(c_int, 1), plan.line_step);
    try std.testing.expectEqual(@as(c_int, 5), plan.line_offset);
    try std.testing.expectEqual(@as(c_int, 0), plan.selscroll_delta);
    try std.testing.expectEqual(@as(c_int, 0), plan.clear_y1);
    try std.testing.expectEqual(@as(c_int, 4), plan.clear_y2);
    try std.testing.expectEqual(@as(c_int, 5), plan.dirty_top);
    try std.testing.expectEqual(@as(c_int, 9), plan.dirty_bot);
    try std.testing.expectEqual(@as(c_int, 5), plan.step_count);
    try std.testing.expectEqual(@as(c_int, scroll_step_hist_swap), plan.steps[0].kind);
    try std.testing.expectEqual(@as(c_int, scroll_step_scr_update), plan.steps[1].kind);
    try std.testing.expectEqual(@as(c_int, scroll_step_clear_rect), plan.steps[2].kind);
    try std.testing.expectEqual(@as(c_int, scroll_step_dirty_range), plan.steps[3].kind);
    try std.testing.expectEqual(@as(c_int, scroll_step_line_swap_loop), plan.steps[4].kind);
}

test "scroll plan with zero count keeps no-op line loop" {
    const plan = st_tscrollplan(0, 5, 10, 0, 100, 1, 0, 0);

    try std.testing.expectEqual(@as(c_int, 0), plan.count);
    try std.testing.expectEqual(@as(c_int, 5), plan.line_start);
    try std.testing.expectEqual(@as(c_int, 10), plan.line_end);
    try std.testing.expectEqual(@as(c_int, 1), plan.line_step);
    try std.testing.expectEqual(@as(c_int, 0), plan.line_offset);
    try std.testing.expectEqual(@as(c_int, 0), plan.selscroll_delta);
}

test "scroll down plan wraps history head backward" {
    const plan = st_tscrollplan(1, 0, 9, 0, 100, 0, 1, 0);

    try std.testing.expectEqual(@as(c_int, 99), plan.new_histi);
    try std.testing.expectEqual(@as(c_int, 1), plan.hist_swap);
    try std.testing.expectEqual(@as(c_int, 9), plan.hist_line);
    try std.testing.expectEqual(@as(c_int, 9), plan.line_start);
    try std.testing.expectEqual(@as(c_int, 1), plan.line_end);
    try std.testing.expectEqual(@as(c_int, -1), plan.line_step);
    try std.testing.expectEqual(@as(c_int, -1), plan.line_offset);
    try std.testing.expectEqual(@as(c_int, 1), plan.selscroll_delta);
    try std.testing.expectEqual(@as(c_int, 9), plan.clear_y1);
    try std.testing.expectEqual(@as(c_int, 9), plan.clear_y2);
    try std.testing.expectEqual(@as(c_int, 0), plan.dirty_top);
    try std.testing.expectEqual(@as(c_int, 8), plan.dirty_bot);
    try std.testing.expectEqual(@as(c_int, 5), plan.step_count);
    try std.testing.expectEqual(@as(c_int, scroll_step_hist_swap), plan.steps[0].kind);
    try std.testing.expectEqual(@as(c_int, scroll_step_dirty_range), plan.steps[1].kind);
    try std.testing.expectEqual(@as(c_int, scroll_step_clear_rect), plan.steps[2].kind);
    try std.testing.expectEqual(@as(c_int, scroll_step_line_swap_loop), plan.steps[3].kind);
    try std.testing.expectEqual(@as(c_int, scroll_step_selection_scroll), plan.steps[4].kind);
}

test "scroll plan skips history swap when history is unavailable" {
    const plan = st_tscrollplan(1, 0, 9, 0, 0, 0, 1, 0);

    try std.testing.expectEqual(@as(c_int, 0), plan.hist_swap);
    try std.testing.expectEqual(@as(c_int, 0), plan.new_histi);
}

test "keyboard scroll down clamps to current scroll" {
    const plan = st_kscrolldownplan(9, 24, 4);

    try std.testing.expectEqual(@as(c_int, 1), plan.run);
    try std.testing.expectEqual(@as(c_int, 0), plan.new_scr);
    try std.testing.expectEqual(@as(c_int, -4), plan.delta);
    try std.testing.expectEqual(@as(c_int, -4), plan.selscroll_delta);
    try std.testing.expectEqual(@as(c_int, 1), plan.full_dirty);
}

test "keyboard scroll up preserves hist bound" {
    const plan = st_kscrollupplan(5, 24, 90, 100);

    try std.testing.expectEqual(@as(c_int, 1), plan.run);
    try std.testing.expectEqual(@as(c_int, 95), plan.new_scr);
    try std.testing.expectEqual(@as(c_int, 5), plan.delta);
    try std.testing.expectEqual(@as(c_int, 5), plan.selscroll_delta);
    try std.testing.expectEqual(@as(c_int, 1), plan.full_dirty);
}
