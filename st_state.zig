//! st_state.zig 负责 scroll region、resize、reset 和 tab reset 的纯规划。
//! [输入]: scroll region 边界、resize 尺寸、tab stops、默认颜色和终端行数。
//! [输出]: `ZigScrollRegion`、`ZigResizeExecPlan`、`ZigResetExecPlan` 或 tab reset 写入。
//! [副作用边界]: 不调用 `tsetscroll(...)` / `tcursor(...)`，不修改光标或 scroll region；这些保留在 C executor。
//! [定位]: 支撑 C executor 的状态变更边界；CSI state 顶层分类已收敛到 `st_csi.zig`。

const std = @import("std");
const term_update = @import("st_term_update.zig");

pub const ZigStatePlan = extern struct {
    kind: c_int,
    top: c_int,
    bottom: c_int,
    cursor_home: c_int,
};

pub const ZigScrollRegion = extern struct {
    top: c_int,
    bottom: c_int,
};

pub const ZigTermStateUpdate = term_update.ZigTermStateUpdate;

pub const ZigResizePlan = extern struct {
    invalid: c_int,
    requested_col: c_int,
    alloc_col: c_int,
    base_maxcol: c_int,
    minrow: c_int,
    mincol: c_int,
    slide_count: c_int,
    tail_start: c_int,
    resize_rows: c_int,
    new_row_start: c_int,
};

pub const ZigResetPlan = extern struct {
    cursor_attr_mode: c_ushort,
    cursor_fg: u32,
    cursor_bg: u32,
    cursor_x: c_int,
    cursor_y: c_int,
    cursor_state: c_int,
    top: c_int,
    bot: c_int,
    mode: c_int,
    charset: c_int,
    trantbl: c_int,
};

pub const ZigResetScreenStep = extern struct {
    move_home: c_int,
    save_cursor: c_int,
    clear: c_int,
    swap_screen: c_int,
};

pub const ZigResetExecPlan = extern struct {
    state: ZigResetPlan,
    screen_step_count: c_int,
    screen_steps: [2]ZigResetScreenStep,
    term_update: ZigTermStateUpdate,
};

const ZigClearRect = extern struct {
    x1: c_int,
    y1: c_int,
    x2: c_int,
    y2: c_int,
};

pub const ZigResizeClearPlan = extern struct {
    count: c_int,
    rects: [2]ZigClearRect,
};

pub const ZigResizeTabPlan = extern struct {
    grow: c_int,
    clear_start: c_int,
    clear_count: c_int,
    tab_start: c_int,
};

pub const ZigResizeFillPlan = extern struct {
    run: c_int,
    start: c_int,
    end: c_int,
};

pub const ZigResizeRowPlan = extern struct {
    resize_start: c_int,
    resize_end: c_int,
    alloc_start: c_int,
    alloc_end: c_int,
};

pub const ZigResizeExecPlan = extern struct {
    base: ZigResizePlan,
    hist_fill: ZigResizeFillPlan,
    rows: ZigResizeRowPlan,
    tabs: ZigResizeTabPlan,
    clear: ZigResizeClearPlan,
    step_count: c_int,
    steps: [10]c_int,
    term_update: ZigTermStateUpdate,
};

pub const resize_step_free_slide_rows = 1;
pub const resize_step_memmove_slide_rows = 2;
pub const resize_step_free_tail_rows = 3;
pub const resize_step_realloc_arrays = 4;
pub const resize_step_fill_history = 5;
pub const resize_step_realloc_rows = 6;
pub const resize_step_alloc_rows = 7;
pub const resize_step_tabs = 8;
pub const resize_step_update_dimensions = 9;
pub const resize_step_clear_regions = 10;

pub const state_unknown = 0;
pub const state_set_scroll = 1;
pub const state_save_cursor = 2;
pub const state_load_cursor = 3;

const attr_null: c_ushort = 0;
const cursor_default = 0;
const mode_wrap = 1 << 0;
const mode_utf8 = 1 << 6;
const charset_usa = 3;

const ScrollBounds = struct {
    top: c_int,
    bottom: c_int,
    row: c_int,

    fn region(self: ScrollBounds) ZigScrollRegion {
        var top = limitInt(self.top, 0, self.row - 1);
        var bottom = limitInt(self.bottom, 0, self.row - 1);

        if (top > bottom) {
            const tmp = top;
            top = bottom;
            bottom = tmp;
        }

        return .{ .top = top, .bottom = bottom };
    }
};

const ResizeRequest = struct {
    requested_col: c_int,
    requested_row: c_int,
    current_col: c_int,
    current_row: c_int,
    current_maxcol: c_int,
    cursor_y: c_int,

    fn plan(self: ResizeRequest) ZigResizePlan {
        const base_maxcol = if (self.current_maxcol == 0) self.current_col else self.current_maxcol;
        const alloc_col = maxInt(self.requested_col, base_maxcol);
        const slide_count = if (self.cursor_y >= self.requested_row) self.cursor_y - self.requested_row + 1 else 0;

        return .{
            .invalid = if (alloc_col < 1 or self.requested_row < 1) 1 else 0,
            .requested_col = self.requested_col,
            .alloc_col = alloc_col,
            .base_maxcol = base_maxcol,
            .minrow = minInt(self.requested_row, self.current_row),
            .mincol = minInt(alloc_col, base_maxcol),
            .slide_count = slide_count,
            .tail_start = slide_count + self.requested_row,
            .resize_rows = minInt(self.requested_row, self.current_row),
            .new_row_start = minInt(self.requested_row, self.current_row),
        };
    }
};

const ResizeTabs = struct {
    tabs: []const c_int,
    old_col: c_int,
    new_col: c_int,
    tabspaces: c_int,

    fn start(self: ResizeTabs) c_int {
        if (self.old_col <= 0) return self.tabspaces;

        var index = self.old_col - 1;
        while (index > 0 and self.tabs[@intCast(index)] == 0) {
            index -= 1;
        }
        return index + self.tabspaces;
    }

    fn plan(self: ResizeTabs) ZigResizeTabPlan {
        if (self.new_col <= self.old_col) {
            return .{ .grow = 0, .clear_start = self.old_col, .clear_count = 0, .tab_start = self.old_col };
        }
        return .{
            .grow = 1,
            .clear_start = self.old_col,
            .clear_count = self.new_col - self.old_col,
            .tab_start = self.start(),
        };
    }
};

const ResizeFill = struct {
    start: c_int,
    end: c_int,

    fn plan(self: ResizeFill) ZigResizeFillPlan {
        if (self.start >= self.end) return .{ .run = 0, .start = self.start, .end = self.end };
        return .{ .run = 1, .start = self.start, .end = self.end };
    }
};

const ResizeRows = struct {
    resize_end: c_int,
    alloc_start: c_int,
    alloc_end: c_int,

    fn plan(self: ResizeRows) ZigResizeRowPlan {
        return .{
            .resize_start = 0,
            .resize_end = self.resize_end,
            .alloc_start = self.alloc_start,
            .alloc_end = self.alloc_end,
        };
    }
};

const ResizeExec = struct {
    request: ResizeRequest,
    tabs: []const c_int,
    tabspaces: c_int,

    fn plan(self: ResizeExec) ZigResizeExecPlan {
        const base = self.request.plan();
        var result = ZigResizeExecPlan{
            .base = base,
            .hist_fill = (ResizeFill{ .start = base.mincol, .end = base.alloc_col }).plan(),
            .rows = (ResizeRows{ .resize_end = base.resize_rows, .alloc_start = base.new_row_start, .alloc_end = self.request.requested_row }).plan(),
            .tabs = (ResizeTabs{ .tabs = self.tabs, .old_col = base.base_maxcol, .new_col = base.alloc_col, .tabspaces = self.tabspaces }).plan(),
            .clear = (ResizeClear{ .mincol = base.mincol, .col = base.alloc_col, .minrow = base.minrow, .row = self.request.requested_row }).plan(),
            .step_count = 0,
            .steps = std.mem.zeroes([10]c_int),
            .term_update = resizeTermUpdate(base, self.request.requested_row),
        };
        addResizeStep(&result, resize_step_free_slide_rows);
        addResizeStep(&result, resize_step_memmove_slide_rows);
        addResizeStep(&result, resize_step_free_tail_rows);
        addResizeStep(&result, resize_step_realloc_arrays);
        addResizeStep(&result, resize_step_fill_history);
        addResizeStep(&result, resize_step_realloc_rows);
        addResizeStep(&result, resize_step_alloc_rows);
        addResizeStep(&result, resize_step_tabs);
        addResizeStep(&result, resize_step_update_dimensions);
        addResizeStep(&result, resize_step_clear_regions);
        return result;
    }
};

fn addResizeStep(plan: *ZigResizeExecPlan, step: c_int) void {
    if (@as(usize, @intCast(plan.step_count)) >= plan.steps.len) return;
    plan.steps[@intCast(plan.step_count)] = step;
    plan.step_count += 1;
}

const ResetRequest = struct {
    default_fg: u32,
    default_bg: u32,
    row: c_int,

    fn plan(self: ResetRequest) ZigResetPlan {
        return .{
            .cursor_attr_mode = attr_null,
            .cursor_fg = self.default_fg,
            .cursor_bg = self.default_bg,
            .cursor_x = 0,
            .cursor_y = 0,
            .cursor_state = cursor_default,
            .top = 0,
            .bot = self.row - 1,
            .mode = mode_wrap | mode_utf8,
            .charset = 0,
            .trantbl = charset_usa,
        };
    }
};

const ResetExec = struct {
    request: ResetRequest,

    fn plan(self: ResetExec) ZigResetExecPlan {
        const state = self.request.plan();
        return .{
            .state = state,
            .screen_step_count = 2,
            .screen_steps = [_]ZigResetScreenStep{ resetScreenStep(), resetScreenStep() },
            .term_update = resetTermUpdate(state),
        };
    }
};

const TabReset = struct {
    tabs: []c_int,
    col: c_int,
    tabspaces: c_uint,

    fn apply(self: TabReset) void {
        var x: c_int = 0;
        while (x < self.col) : (x += 1) {
            self.tabs[@intCast(x)] = 0;
        }

        var tab = self.tabspaces;
        while (tab < @as(c_uint, @intCast(self.col))) : (tab += self.tabspaces) {
            self.tabs[@intCast(tab)] = 1;
        }
    }
};

const ResizeClear = struct {
    mincol: c_int,
    col: c_int,
    minrow: c_int,
    row: c_int,

    fn plan(self: ResizeClear) ZigResizeClearPlan {
        var result = ZigResizeClearPlan{ .count = 0, .rects = std.mem.zeroes([2]ZigClearRect) };
        if (self.mincol < self.col and 0 < self.minrow) addResizeRect(&result, self.mincol, 0, self.col - 1, self.minrow - 1);
        if (0 < self.col and self.minrow < self.row) addResizeRect(&result, 0, self.minrow, self.col - 1, self.row - 1);
        return result;
    }
};

export fn st_tsetscroll(t: c_int, b: c_int, row: c_int) ZigScrollRegion {
    return (ScrollBounds{ .top = t, .bottom = b, .row = row }).region();
}

export fn st_tresizeexecplan(tabs: [*]const c_int, requested_col: c_int, requested_row: c_int, current_col: c_int, current_row: c_int, current_maxcol: c_int, cursor_y: c_int, tabspaces: c_int) ZigResizeExecPlan {
    const request = ResizeRequest{ .requested_col = requested_col, .requested_row = requested_row, .current_col = current_col, .current_row = current_row, .current_maxcol = current_maxcol, .cursor_y = cursor_y };
    const base_maxcol = if (current_maxcol == 0) current_col else current_maxcol;
    const tab_count = if (base_maxcol > 0) base_maxcol else 0;
    return (ResizeExec{ .request = request, .tabs = tabs[0..@intCast(tab_count)], .tabspaces = tabspaces }).plan();
}

export fn st_tresetexecplan(default_fg: u32, default_bg: u32, row: c_int) ZigResetExecPlan {
    return (ResetExec{ .request = .{ .default_fg = default_fg, .default_bg = default_bg, .row = row } }).plan();
}

export fn st_tresettabs(tabs: [*]c_int, col: c_int, tabspaces: c_uint) void {
    (TabReset{ .tabs = tabs[0..@intCast(col)], .col = col, .tabspaces = tabspaces }).apply();
}

fn limitInt(value: c_int, lower: c_int, upper: c_int) c_int {
    if (value < lower) return lower;
    if (value > upper) return upper;
    return value;
}

fn minInt(a: c_int, b: c_int) c_int {
    return if (a < b) a else b;
}

fn maxInt(a: c_int, b: c_int) c_int {
    return if (a > b) a else b;
}

fn addResizeRect(plan: *ZigResizeClearPlan, x1: c_int, y1: c_int, x2: c_int, y2: c_int) void {
    if (plan.count >= plan.rects.len) return;
    plan.rects[@intCast(plan.count)] = .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 };
    plan.count += 1;
}

fn resetTermUpdate(state: ZigResetPlan) ZigTermStateUpdate {
    var update = std.mem.zeroes(ZigTermStateUpdate);
    update.set_cursor = 1;
    update.cursor_attr_mode = state.cursor_attr_mode;
    update.cursor_fg = state.cursor_fg;
    update.cursor_bg = state.cursor_bg;
    update.cursor_x = state.cursor_x;
    update.cursor_y = state.cursor_y;
    update.cursor_state = state.cursor_state;
    update.mode_mask = ~@as(c_int, 0);
    update.mode_bits = state.mode;
    update.set_charset = 1;
    update.charset = state.charset;
    update.set_all_trantbl = 1;
    update.all_trantbl_charset = state.trantbl;
    update.set_scroll_region = 1;
    update.top = state.top;
    update.bot = state.bot;
    return update;
}

fn resizeTermUpdate(base: ZigResizePlan, row: c_int) ZigTermStateUpdate {
    var update = std.mem.zeroes(ZigTermStateUpdate);
    update.set_dimensions = 1;
    update.col = base.requested_col;
    update.maxcol = base.alloc_col;
    update.row = row;
    update.set_scroll_region = 1;
    update.top = 0;
    update.bot = row - 1;
    update.clamp_cursor = 1;
    return update;
}

fn resetScreenStep() ZigResetScreenStep {
    return .{ .move_home = 1, .save_cursor = 1, .clear = 1, .swap_screen = 1 };
}

test "tsetscroll clamps to terminal rows" {
    const region = st_tsetscroll(-3, 99, 24);

    try std.testing.expectEqual(@as(c_int, 0), region.top);
    try std.testing.expectEqual(@as(c_int, 23), region.bottom);
}

test "tsetscroll sorts inverted bounds after clamp" {
    const region = st_tsetscroll(20, 4, 24);

    try std.testing.expectEqual(@as(c_int, 4), region.top);
    try std.testing.expectEqual(@as(c_int, 20), region.bottom);
}

test "tresize plan preserves requested and alloc columns" {
    const tabs = [_]c_int{0} ** 100;
    const plan = st_tresizeexecplan(&tabs, 80, 24, 100, 30, 0, 10, 8).base;

    try std.testing.expectEqual(@as(c_int, 0), plan.invalid);
    try std.testing.expectEqual(@as(c_int, 80), plan.requested_col);
    try std.testing.expectEqual(@as(c_int, 100), plan.alloc_col);
    try std.testing.expectEqual(@as(c_int, 100), plan.base_maxcol);
    try std.testing.expectEqual(@as(c_int, 24), plan.minrow);
    try std.testing.expectEqual(@as(c_int, 100), plan.mincol);
    try std.testing.expectEqual(@as(c_int, 24), plan.resize_rows);
    try std.testing.expectEqual(@as(c_int, 24), plan.new_row_start);
}

test "tresize plan computes slide and tail free bounds" {
    const tabs = [_]c_int{0} ** 100;
    const plan = st_tresizeexecplan(&tabs, 120, 20, 100, 30, 100, 25, 8).base;

    try std.testing.expectEqual(@as(c_int, 6), plan.slide_count);
    try std.testing.expectEqual(@as(c_int, 26), plan.tail_start);
}

test "tresize exec plan groups dependent ranges" {
    const tabs = [_]c_int{0} ** 100;
    const plan = st_tresizeexecplan(&tabs, 120, 20, 100, 30, 100, 25, 8);

    try std.testing.expectEqual(@as(c_int, 100), plan.hist_fill.start);
    try std.testing.expectEqual(@as(c_int, 120), plan.hist_fill.end);
    try std.testing.expectEqual(@as(c_int, 20), plan.rows.resize_end);
    try std.testing.expectEqual(@as(c_int, 20), plan.rows.alloc_start);
    try std.testing.expectEqual(@as(c_int, 20), plan.rows.alloc_end);
    try std.testing.expectEqual(@as(c_int, 1), plan.clear.count);
    try std.testing.expectEqual(@as(c_int, 10), plan.step_count);
    try std.testing.expectEqual(@as(c_int, resize_step_free_slide_rows), plan.steps[0]);
    try std.testing.expectEqual(@as(c_int, resize_step_memmove_slide_rows), plan.steps[1]);
    try std.testing.expectEqual(@as(c_int, resize_step_free_tail_rows), plan.steps[2]);
    try std.testing.expectEqual(@as(c_int, resize_step_realloc_arrays), plan.steps[3]);
    try std.testing.expectEqual(@as(c_int, resize_step_fill_history), plan.steps[4]);
    try std.testing.expectEqual(@as(c_int, resize_step_realloc_rows), plan.steps[5]);
    try std.testing.expectEqual(@as(c_int, resize_step_alloc_rows), plan.steps[6]);
    try std.testing.expectEqual(@as(c_int, resize_step_tabs), plan.steps[7]);
    try std.testing.expectEqual(@as(c_int, resize_step_update_dimensions), plan.steps[8]);
    try std.testing.expectEqual(@as(c_int, resize_step_clear_regions), plan.steps[9]);
}

test "tresize tab plan continues after previous tab" {
    const tabs = [_]c_int{ 0, 0, 0, 0, 1, 0, 0, 0 };

    try std.testing.expectEqual(@as(c_int, 8), st_tresizeexecplan(&tabs, 12, 24, tabs.len, 24, tabs.len, 0, 4).tabs.tab_start);
}

test "tresize tab plan falls back from no previous tab" {
    const tabs = [_]c_int{ 0, 0, 0, 0 };

    try std.testing.expectEqual(@as(c_int, 4), st_tresizeexecplan(&tabs, 8, 24, tabs.len, 24, tabs.len, 0, 4).tabs.tab_start);
}

test "tresize tab plan handles empty old columns" {
    const tabs = [_]c_int{};

    try std.testing.expectEqual(@as(c_int, 4), st_tresizeexecplan(&tabs, 8, 24, 0, 24, 0, 0, 4).tabs.tab_start);
}

test "tresize tab plan describes growth range" {
    const tabs = [_]c_int{ 0, 0, 0, 0, 1, 0, 0, 0 };
    const plan = st_tresizeexecplan(&tabs, 12, 24, tabs.len, 24, tabs.len, 0, 4).tabs;

    try std.testing.expectEqual(@as(c_int, 1), plan.grow);
    try std.testing.expectEqual(@as(c_int, 8), plan.clear_start);
    try std.testing.expectEqual(@as(c_int, 4), plan.clear_count);
    try std.testing.expectEqual(@as(c_int, 8), plan.tab_start);

    const unchanged = st_tresizeexecplan(&tabs, 6, 24, tabs.len, 24, tabs.len, 0, 4).tabs;
    try std.testing.expectEqual(@as(c_int, 0), unchanged.grow);
    try std.testing.expectEqual(@as(c_int, 0), unchanged.clear_count);
}

test "tresize fill plan skips empty ranges" {
    const grow = (ResizeFill{ .start = 5, .end = 10 }).plan();
    try std.testing.expectEqual(@as(c_int, 1), grow.run);
    try std.testing.expectEqual(@as(c_int, 5), grow.start);
    try std.testing.expectEqual(@as(c_int, 10), grow.end);

    const same = (ResizeFill{ .start = 10, .end = 10 }).plan();
    try std.testing.expectEqual(@as(c_int, 0), same.run);

    const inverted = (ResizeFill{ .start = 12, .end = 10 }).plan();
    try std.testing.expectEqual(@as(c_int, 0), inverted.run);
}

test "tresize row plan exposes resize and alloc ranges" {
    const plan = (ResizeRows{ .resize_end = 20, .alloc_start = 20, .alloc_end = 24 }).plan();
    try std.testing.expectEqual(@as(c_int, 0), plan.resize_start);
    try std.testing.expectEqual(@as(c_int, 20), plan.resize_end);
    try std.testing.expectEqual(@as(c_int, 20), plan.alloc_start);
    try std.testing.expectEqual(@as(c_int, 24), plan.alloc_end);
}

test "treset plan sets default terminal state" {
    const plan = (ResetRequest{ .default_fg = 7, .default_bg = 8, .row = 24 }).plan();

    try std.testing.expectEqual(@as(c_ushort, attr_null), plan.cursor_attr_mode);
    try std.testing.expectEqual(@as(u32, 7), plan.cursor_fg);
    try std.testing.expectEqual(@as(u32, 8), plan.cursor_bg);
    try std.testing.expectEqual(@as(c_int, 0), plan.top);
    try std.testing.expectEqual(@as(c_int, 23), plan.bot);
    try std.testing.expectEqual(@as(c_int, mode_wrap | mode_utf8), plan.mode);
    try std.testing.expectEqual(@as(c_int, charset_usa), plan.trantbl);
}

test "treset exec plan owns double screen reset ordering" {
    const plan = st_tresetexecplan(7, 8, 24);

    try std.testing.expectEqual(@as(c_int, 2), plan.screen_step_count);
    for (plan.screen_steps) |step| {
        try std.testing.expectEqual(@as(c_int, 1), step.move_home);
        try std.testing.expectEqual(@as(c_int, 1), step.save_cursor);
        try std.testing.expectEqual(@as(c_int, 1), step.clear);
        try std.testing.expectEqual(@as(c_int, 1), step.swap_screen);
    }
}

test "treset tabs marks configured stops" {
    var tabs = [_]c_int{ 1, 1, 1, 1, 1, 1, 1, 1, 1 };

    st_tresettabs(&tabs, tabs.len, 4);

    try std.testing.expectEqualSlices(c_int, &[_]c_int{ 0, 0, 0, 0, 1, 0, 0, 0, 1 }, &tabs);
}

test "tresize clear plan emits width and height regions" {
    const plan = (ResizeClear{ .mincol = 5, .col = 10, .minrow = 3, .row = 6 }).plan();

    try std.testing.expectEqual(@as(c_int, 2), plan.count);
    try std.testing.expectEqual(ZigClearRect{ .x1 = 5, .y1 = 0, .x2 = 9, .y2 = 2 }, plan.rects[0]);
    try std.testing.expectEqual(ZigClearRect{ .x1 = 0, .y1 = 3, .x2 = 9, .y2 = 5 }, plan.rects[1]);
}
