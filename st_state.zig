//! st_state.zig 负责 CSI 状态类序列的纯规划。
//! [输入]: CSI mode、private marker、参数数组、终端行数、scroll region 边界和 resize 尺寸。
//! [输出]: `ZigStatePlan` / `ZigScrollRegion` / `ZigResizePlan`，描述设置滚动区域、保存光标、恢复光标、最终 scroll region 或 resize 边界。
//! [副作用边界]: 不调用 `tsetscroll(...)` / `tcursor(...)`，不修改光标或 scroll region；这些保留在 C executor。
//! [定位]: 收敛 `csihandle(...)` 中 `r/s/u` 分支和 `tsetscroll(...)` 的 clamp 主体，并保持 unknown 路径由 C 处理。

const std = @import("std");

pub const ZigStatePlan = extern struct {
    kind: c_int,
    top: c_int,
    bottom: c_int,
};

pub const ZigScrollRegion = extern struct {
    top: c_int,
    bottom: c_int,
};

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
};

pub const state_unknown = 0;
pub const state_set_scroll = 1;
pub const state_save_cursor = 2;
pub const state_load_cursor = 3;

const attr_null: c_ushort = 0;
const cursor_default = 0;
const mode_wrap = 1 << 0;
const mode_utf8 = 1 << 6;
const charset_usa = 3;

const CsiCommand = struct {
    mode: c_char,
    private: bool,
    args: []const c_int,
    row: c_int,

    fn plan(self: CsiCommand) ZigStatePlan {
        return switch (self.mode) {
            'r' => if (self.private)
                .{ .kind = state_unknown, .top = 0, .bottom = 0 }
            else
                .{
                    .kind = state_set_scroll,
                    .top = defaultArg(self.args, 0, 1) - 1,
                    .bottom = defaultArg(self.args, 1, self.row) - 1,
                },
            's' => .{ .kind = state_save_cursor, .top = 0, .bottom = 0 },
            'u' => .{ .kind = state_load_cursor, .top = 0, .bottom = 0 },
            else => .{ .kind = state_unknown, .top = 0, .bottom = 0 },
        };
    }
};

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
        return .{
            .base = base,
            .hist_fill = (ResizeFill{ .start = base.mincol, .end = base.alloc_col }).plan(),
            .rows = (ResizeRows{ .resize_end = base.resize_rows, .alloc_start = base.new_row_start, .alloc_end = self.request.requested_row }).plan(),
            .tabs = (ResizeTabs{ .tabs = self.tabs, .old_col = base.base_maxcol, .new_col = base.alloc_col, .tabspaces = self.tabspaces }).plan(),
            .clear = (ResizeClear{ .mincol = base.mincol, .col = base.alloc_col, .minrow = base.minrow, .row = self.request.requested_row }).plan(),
        };
    }
};

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

fn planState(mode: c_char, priv: c_int, arg: [*]const c_int, len: c_int, row: c_int) ZigStatePlan {
    const args = arg[0..@intCast(len)];
    return (CsiCommand{ .mode = mode, .private = priv != 0, .args = args, .row = row }).plan();
}

export fn st_tsetscroll(t: c_int, b: c_int, row: c_int) ZigScrollRegion {
    return (ScrollBounds{ .top = t, .bottom = b, .row = row }).region();
}

export fn st_tresizeexecplan(tabs: [*]const c_int, requested_col: c_int, requested_row: c_int, current_col: c_int, current_row: c_int, current_maxcol: c_int, cursor_y: c_int, tabspaces: c_int) ZigResizeExecPlan {
    const request = ResizeRequest{ .requested_col = requested_col, .requested_row = requested_row, .current_col = current_col, .current_row = current_row, .current_maxcol = current_maxcol, .cursor_y = cursor_y };
    const base_maxcol = if (current_maxcol == 0) current_col else current_maxcol;
    const tab_count = if (base_maxcol > 0) base_maxcol else 0;
    return (ResizeExec{ .request = request, .tabs = tabs[0..@intCast(tab_count)], .tabspaces = tabspaces }).plan();
}

export fn st_tresetplan(default_fg: u32, default_bg: u32, row: c_int) ZigResetPlan {
    return (ResetRequest{ .default_fg = default_fg, .default_bg = default_bg, .row = row }).plan();
}

export fn st_tresettabs(tabs: [*]c_int, col: c_int, tabspaces: c_uint) void {
    (TabReset{ .tabs = tabs[0..@intCast(col)], .col = col, .tabspaces = tabspaces }).apply();
}

fn defaultArg(args: []const c_int, index: usize, fallback: c_int) c_int {
    if (index >= args.len) return fallback;
    return if (args[index] == 0) fallback else args[index];
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

test "plan r defaults to full screen scroll region" {
    const plan = planState('r', 0, &[_]c_int{ 0, 0 }, 2, 24);
    try std.testing.expectEqual(@as(c_int, state_set_scroll), plan.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.top);
    try std.testing.expectEqual(@as(c_int, 23), plan.bottom);
}

test "plan r uses explicit bounds" {
    const plan = planState('r', 0, &[_]c_int{ 2, 10 }, 2, 24);
    try std.testing.expectEqual(@as(c_int, state_set_scroll), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.top);
    try std.testing.expectEqual(@as(c_int, 9), plan.bottom);
}

test "plan r with private marker is unknown" {
    const plan = planState('r', 1, &[_]c_int{ 2, 10 }, 2, 24);
    try std.testing.expectEqual(@as(c_int, state_unknown), plan.kind);
}

test "plan s saves cursor" {
    const plan = planState('s', 0, &[_]c_int{}, 0, 24);
    try std.testing.expectEqual(@as(c_int, state_save_cursor), plan.kind);
}

test "plan u loads cursor" {
    const plan = planState('u', 0, &[_]c_int{}, 0, 24);
    try std.testing.expectEqual(@as(c_int, state_load_cursor), plan.kind);
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
    const plan = st_tresetplan(7, 8, 24);

    try std.testing.expectEqual(@as(c_ushort, attr_null), plan.cursor_attr_mode);
    try std.testing.expectEqual(@as(u32, 7), plan.cursor_fg);
    try std.testing.expectEqual(@as(u32, 8), plan.cursor_bg);
    try std.testing.expectEqual(@as(c_int, 0), plan.top);
    try std.testing.expectEqual(@as(c_int, 23), plan.bot);
    try std.testing.expectEqual(@as(c_int, mode_wrap | mode_utf8), plan.mode);
    try std.testing.expectEqual(@as(c_int, charset_usa), plan.trantbl);
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
