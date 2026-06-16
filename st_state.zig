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
    tabspaces: c_int,

    fn start(self: ResizeTabs) c_int {
        if (self.old_col <= 0) return self.tabspaces;

        var index = self.old_col - 1;
        while (index > 0 and self.tabs[@intCast(index)] == 0) {
            index -= 1;
        }
        return index + self.tabspaces;
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

export fn st_planstate(mode: c_char, priv: c_int, arg: [*]const c_int, len: c_int, row: c_int) ZigStatePlan {
    const args = arg[0..@intCast(len)];
    return (CsiCommand{ .mode = mode, .private = priv != 0, .args = args, .row = row }).plan();
}

export fn st_tsetscroll(t: c_int, b: c_int, row: c_int) ZigScrollRegion {
    return (ScrollBounds{ .top = t, .bottom = b, .row = row }).region();
}

export fn st_tresizeplan(requested_col: c_int, requested_row: c_int, current_col: c_int, current_row: c_int, current_maxcol: c_int, cursor_y: c_int) ZigResizePlan {
    return (ResizeRequest{ .requested_col = requested_col, .requested_row = requested_row, .current_col = current_col, .current_row = current_row, .current_maxcol = current_maxcol, .cursor_y = cursor_y }).plan();
}

export fn st_tresizetabstart(tabs: [*]const c_int, old_col: c_int, tabspaces: c_int) c_int {
    const tab_count = if (old_col > 0) old_col else 0;
    return (ResizeTabs{ .tabs = tabs[0..@intCast(tab_count)], .old_col = old_col, .tabspaces = tabspaces }).start();
}

export fn st_tresetplan(default_fg: u32, default_bg: u32, row: c_int) ZigResetPlan {
    return (ResetRequest{ .default_fg = default_fg, .default_bg = default_bg, .row = row }).plan();
}

export fn st_tresettabs(tabs: [*]c_int, col: c_int, tabspaces: c_uint) void {
    (TabReset{ .tabs = tabs[0..@intCast(col)], .col = col, .tabspaces = tabspaces }).apply();
}

export fn st_tresizeclearplan(mincol: c_int, col: c_int, minrow: c_int, row: c_int) ZigResizeClearPlan {
    return (ResizeClear{ .mincol = mincol, .col = col, .minrow = minrow, .row = row }).plan();
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
    const plan = st_planstate('r', 0, &[_]c_int{ 0, 0 }, 2, 24);
    try std.testing.expectEqual(@as(c_int, state_set_scroll), plan.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.top);
    try std.testing.expectEqual(@as(c_int, 23), plan.bottom);
}

test "plan r uses explicit bounds" {
    const plan = st_planstate('r', 0, &[_]c_int{ 2, 10 }, 2, 24);
    try std.testing.expectEqual(@as(c_int, state_set_scroll), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.top);
    try std.testing.expectEqual(@as(c_int, 9), plan.bottom);
}

test "plan r with private marker is unknown" {
    const plan = st_planstate('r', 1, &[_]c_int{ 2, 10 }, 2, 24);
    try std.testing.expectEqual(@as(c_int, state_unknown), plan.kind);
}

test "plan s saves cursor" {
    const plan = st_planstate('s', 0, &[_]c_int{}, 0, 24);
    try std.testing.expectEqual(@as(c_int, state_save_cursor), plan.kind);
}

test "plan u loads cursor" {
    const plan = st_planstate('u', 0, &[_]c_int{}, 0, 24);
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
    const plan = st_tresizeplan(80, 24, 100, 30, 0, 10);

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
    const plan = st_tresizeplan(120, 20, 100, 30, 100, 25);

    try std.testing.expectEqual(@as(c_int, 6), plan.slide_count);
    try std.testing.expectEqual(@as(c_int, 26), plan.tail_start);
}

test "tresize tab start continues after previous tab" {
    const tabs = [_]c_int{ 0, 0, 0, 0, 1, 0, 0, 0 };

    try std.testing.expectEqual(@as(c_int, 8), st_tresizetabstart(&tabs, tabs.len, 4));
}

test "tresize tab start falls back from no previous tab" {
    const tabs = [_]c_int{ 0, 0, 0, 0 };

    try std.testing.expectEqual(@as(c_int, 4), st_tresizetabstart(&tabs, tabs.len, 4));
}

test "tresize tab start handles empty old columns" {
    const tabs = [_]c_int{};

    try std.testing.expectEqual(@as(c_int, 4), st_tresizetabstart(&tabs, 0, 4));
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
    const plan = st_tresizeclearplan(5, 10, 3, 6);

    try std.testing.expectEqual(@as(c_int, 2), plan.count);
    try std.testing.expectEqual(ZigClearRect{ .x1 = 5, .y1 = 0, .x2 = 9, .y2 = 2 }, plan.rects[0]);
    try std.testing.expectEqual(ZigClearRect{ .x1 = 0, .y1 = 3, .x2 = 9, .y2 = 5 }, plan.rects[1]);
}
