//! selection 领域状态机，不直接暴露 C ABI。
//! [输入]: 值类型坐标、glyph mode、delimiter 状态。
//! [输出]: selection/snap 的内部决策结果。
//! [定位]: 承载 selection 相关纯逻辑，C adapter 只负责转换 extern struct。

const std = @import("std");
const model = @import("term_model.zig");

pub const SnapPrev = struct {
    delim: i32,
    rune: model.Rune,
};

pub const Bounds = struct {
    start: model.Point,
    end: model.Point,

    pub fn columns(self: Bounds, selection_type: SelectionType, start_len: i32, end_len: i32, cols: i32) Bounds {
        if (selection_type == .rectangular) return self;
        return .{
            .start = .{ .x = if (start_len < self.start.x) start_len else self.start.x, .y = self.start.y },
            .end = .{ .x = if (end_len <= self.end.x) cols - 1 else self.end.x, .y = self.end.y },
        };
    }

    pub fn contains(self: Bounds, point: model.Point, active: bool, alt_matches: bool, selection_type: SelectionType) bool {
        if (!active or !alt_matches) return false;
        const ordered = normalize(selection_type, self.start, self.end);

        return switch (selection_type) {
            .rectangular => between(point.y, ordered.start.y, ordered.end.y) and between(point.x, ordered.start.x, ordered.end.x),
            .regular => between(point.y, ordered.start.y, ordered.end.y) and (point.y != ordered.start.y or point.x >= ordered.start.x) and (point.y != ordered.end.y or point.x <= ordered.end.x),
        };
    }

    pub fn linePlan(self: Bounds, selection_type: SelectionType, y: i32, cols: i32) GetLinePlan {
        if (selection_type == .rectangular) return .{ .start_x = self.start.x, .last_x = self.end.x };
        return .{
            .start_x = if (self.start.y == y) self.start.x else 0,
            .last_x = if (self.end.y == y) self.end.x else cols - 1,
        };
    }

    pub fn bufferSize(self: Bounds, cols: i32, utf_size: i32) i32 {
        return (cols + 1) * (self.end.y - self.start.y + 1) * utf_size;
    }

    pub fn needsNewline(self: Bounds, y: i32, last_x: i32, linelen: i32, last_mode: u16, selection_type: SelectionType) bool {
        const crosses_line = y < self.end.y or last_x >= linelen;
        const can_break = !model.hasWrap(last_mode) or selection_type == .rectangular;
        return crosses_line and can_break;
    }
};

pub const SelectionType = enum(i32) {
    regular = 1,
    rectangular = 2,
};

pub const SelectionMode = enum(i32) {
    idle = 0,
    empty = 1,
    ready = 2,
};

pub const StartPlan = struct {
    mode: SelectionMode,
    selection_type: SelectionType,
    alt: bool,
    snap: i32,
    point: model.Point,
    final_mode: SelectionMode,
};

pub const ScrollAction = enum(i32) {
    none = 0,
    clear = 1,
    normalize = 2,
};

pub const ScrollPlan = struct {
    action: ScrollAction,
    origin_y: i32,
    extent_y: i32,
};

pub const ExtendPlan = struct {
    dirty: bool,
    top: i32,
    bot: i32,
    mode: SelectionMode,
};

pub const SnapWordPlan = struct {
    point: model.Point,
    wrap_point: model.Point,
    wrapped: bool,
    in_bounds: bool,
};

pub const GetLinePlan = struct {
    start_x: i32,
    last_x: i32,
};

pub const SnapWordAction = enum(i32) {
    stop = 0,
    accept = 1,
};

pub const SnapLineAction = enum(i32) {
    stop = 0,
    move = 1,
};

pub const SnapLineStep = union(SnapLineAction) {
    stop: i32,
    move: i32,
};

pub const SnapWordStep = union(enum) {
    stop: SnapPrev,
    accept: struct {
        point: model.Point,
        prev: SnapPrev,
    },
};

pub const SnapWordLoopStep = union(SnapWordAction) {
    stop: SnapPrev,
    accept: struct {
        point: model.Point,
        prev: SnapPrev,
    },
};

pub fn snapLineX(direction: i32, col: i32) i32 {
    return if (direction < 0) 0 else col - 1;
}

pub fn snapLineStep(y: i32, direction: i32, rows: i32, wrapped: bool) SnapLineStep {
    if (direction < 0) {
        if (y <= 0 or !wrapped) return .{ .stop = y };
        return .{ .move = y + direction };
    }
    if (direction > 0) {
        if (y >= rows - 1 or !wrapped) return .{ .stop = y };
        return .{ .move = y + direction };
    }
    return .{ .stop = y };
}

pub fn shouldClear(origin_x: i32) bool {
    return origin_x != -1;
}

pub fn startPlan(point: model.Point, snap: i32, alt_screen: bool) StartPlan {
    return .{
        .mode = .empty,
        .selection_type = .regular,
        .alt = alt_screen,
        .snap = snap,
        .point = point,
        .final_mode = if (snap != 0) .ready else .empty,
    };
}

pub fn scrollPlan(origin_x: i32, origin_y: i32, extent_y: i32, bounds: Bounds, scroll_origin: i32, top: i32, bot: i32, delta: i32) ScrollPlan {
    if (origin_x == -1) return .{ .action = .none, .origin_y = origin_y, .extent_y = extent_y };

    const start_inside = between(bounds.start.y, scroll_origin, bot);
    const end_inside = between(bounds.end.y, scroll_origin, bot);
    if (start_inside != end_inside) return .{ .action = .clear, .origin_y = origin_y, .extent_y = extent_y };
    if (!start_inside) return .{ .action = .none, .origin_y = origin_y, .extent_y = extent_y };

    const next_origin_y = origin_y + delta;
    const next_extent_y = extent_y + delta;
    if (!between(next_origin_y, top, bot) or !between(next_extent_y, top, bot)) {
        return .{ .action = .clear, .origin_y = next_origin_y, .extent_y = next_extent_y };
    }
    return .{ .action = .normalize, .origin_y = next_origin_y, .extent_y = next_extent_y };
}

pub fn extendPlan(old_point: model.Point, old_type: SelectionType, old_bounds: Bounds, new_point: model.Point, new_type: SelectionType, new_bounds: Bounds, old_mode: SelectionMode, done: bool) ExtendPlan {
    const dirty = old_point.y != new_point.y or old_point.x != new_point.x or old_type != new_type or old_mode == .empty;
    const old_top = @min(old_bounds.start.y, old_bounds.end.y);
    const old_bot = @max(old_bounds.start.y, old_bounds.end.y);
    const new_top = @min(new_bounds.start.y, new_bounds.end.y);
    const new_bot = @max(new_bounds.start.y, new_bounds.end.y);
    return .{
        .dirty = dirty,
        .top = @min(new_top, old_top),
        .bot = @max(new_bot, old_bot),
        .mode = if (done) .idle else .ready,
    };
}

pub fn normalize(selection_type: SelectionType, origin: model.Point, extent: model.Point) Bounds {
    if (selection_type == .regular and origin.y != extent.y) {
        return .{
            .start = .{ .x = if (origin.y < extent.y) origin.x else extent.x, .y = @min(origin.y, extent.y) },
            .end = .{ .x = if (origin.y < extent.y) extent.x else origin.x, .y = @max(origin.y, extent.y) },
        };
    }
    return .{
        .start = .{ .x = @min(origin.x, extent.x), .y = @min(origin.y, extent.y) },
        .end = .{ .x = @max(origin.x, extent.x), .y = @max(origin.y, extent.y) },
    };
}

pub fn normalizeColumns(selection_type: SelectionType, bounds: Bounds, start_len: i32, end_len: i32, cols: i32) Bounds {
    return bounds.columns(selection_type, start_len, end_len, cols);
}

pub fn getLinePlan(selection_type: SelectionType, bounds: Bounds, y: i32, cols: i32) GetLinePlan {
    return bounds.linePlan(selection_type, y, cols);
}

pub fn getBufferSize(cols: i32, bounds: Bounds, utf_size: i32) i32 {
    return bounds.bufferSize(cols, utf_size);
}

pub fn getLastX(last_x: i32, linelen: i32) i32 {
    return @min(last_x, linelen - 1);
}

pub fn needsNewline(y: i32, bounds: Bounds, last_x: i32, linelen: i32, last_mode: u16, selection_type: SelectionType) bool {
    return bounds.needsNewline(y, last_x, linelen, last_mode, selection_type);
}

pub fn isSelected(point: model.Point, active: bool, alt_matches: bool, selection_type: SelectionType, bounds: Bounds) bool {
    return bounds.contains(point, active, alt_matches, selection_type);
}

pub fn snapWordPlan(point: model.Point, direction: i32, size: model.Size) SnapWordPlan {
    var next = model.Point{ .x = point.x + direction, .y = point.y };
    var wrapped = false;

    if (!between(next.x, 0, size.cols - 1)) {
        next.y += direction;
        next.x = @mod(next.x + size.cols, size.cols);
        wrapped = true;
        if (!between(next.y, 0, size.rows - 1)) {
            return .{ .point = next, .wrap_point = next, .wrapped = wrapped, .in_bounds = false };
        }
    }

    return .{
        .point = next,
        .wrap_point = if (direction > 0) point else next,
        .wrapped = wrapped,
        .in_bounds = true,
    };
}

pub fn snapWordBreak(mode: u16, delim: i32, prev: SnapPrev, rune: model.Rune) bool {
    const delimiter_changed = delim != prev.delim;
    const delimiter_rune_changed = delim != 0 and rune != prev.rune;
    return !model.hasWideDummy(mode) and (delimiter_changed or delimiter_rune_changed);
}

pub fn snapWordPastLine(x: i32, linelen: i32) bool {
    return x >= linelen;
}

pub fn snapWordStep(point: model.Point, linelen: i32, mode: u16, delim: i32, prev: SnapPrev, rune: model.Rune) SnapWordStep {
    if (snapWordPastLine(point.x, linelen) or snapWordBreak(mode, delim, prev, rune)) {
        return .{ .stop = prev };
    }
    return .{ .accept = .{ .point = point, .prev = .{ .delim = delim, .rune = rune } } };
}

pub fn snapWordLoopStep(plan: SnapWordPlan, wrap_allowed: bool, linelen: i32, mode: u16, delim: i32, prev: SnapPrev, rune: model.Rune) SnapWordLoopStep {
    if (!plan.in_bounds or (plan.wrapped and !wrap_allowed)) return .{ .stop = prev };
    return switch (snapWordStep(plan.point, linelen, mode, delim, prev, rune)) {
        .stop => |stopped| .{ .stop = stopped },
        .accept => |accepted| .{ .accept = .{ .point = accepted.point, .prev = accepted.prev } },
    };
}

fn between(value: i32, lower: i32, upper: i32) bool {
    return lower <= value and value <= upper;
}

test "snap word plan handles wrapping" {
    const forward = snapWordPlan(.{ .x = 9, .y = 2 }, 1, .{ .cols = 10, .rows = 5 });
    try std.testing.expectEqual(model.Point{ .x = 0, .y = 3 }, forward.point);
    try std.testing.expectEqual(model.Point{ .x = 9, .y = 2 }, forward.wrap_point);
    try std.testing.expect(forward.wrapped);
    try std.testing.expect(forward.in_bounds);

    const backward = snapWordPlan(.{ .x = 0, .y = 2 }, -1, .{ .cols = 10, .rows = 5 });
    try std.testing.expectEqual(model.Point{ .x = 9, .y = 1 }, backward.point);
    try std.testing.expectEqual(model.Point{ .x = 9, .y = 1 }, backward.wrap_point);
}

test "selection clear and start plans describe state" {
    try std.testing.expect(!shouldClear(-1));
    try std.testing.expect(shouldClear(0));

    const plan = startPlan(.{ .x = 3, .y = 4 }, 1, true);
    try std.testing.expectEqual(SelectionMode.empty, plan.mode);
    try std.testing.expectEqual(SelectionType.regular, plan.selection_type);
    try std.testing.expect(plan.alt);
    try std.testing.expectEqual(@as(i32, 1), plan.snap);
    try std.testing.expectEqual(model.Point{ .x = 3, .y = 4 }, plan.point);
    try std.testing.expectEqual(SelectionMode.ready, plan.final_mode);
}

test "snap line step moves while wrapped" {
    try std.testing.expectEqual(@as(i32, 0), snapLineX(-1, 10));
    try std.testing.expectEqual(@as(i32, 9), snapLineX(1, 10));
    try std.testing.expectEqual(@as(i32, 2), snapLineStep(3, -1, 5, true).move);
    try std.testing.expectEqual(@as(i32, 3), snapLineStep(3, -1, 5, false).stop);
    try std.testing.expectEqual(@as(i32, 4), snapLineStep(3, 1, 5, true).move);
    try std.testing.expectEqual(@as(i32, 4), snapLineStep(4, 1, 5, true).stop);
}

test "selection scroll plan clears or normalizes affected selection" {
    const bounds = Bounds{ .start = .{ .x = 0, .y = 3 }, .end = .{ .x = 0, .y = 4 } };
    const moved = scrollPlan(0, 3, 4, bounds, 0, 0, 8, 2);
    try std.testing.expectEqual(ScrollAction.normalize, moved.action);
    try std.testing.expectEqual(@as(i32, 5), moved.origin_y);
    try std.testing.expectEqual(@as(i32, 6), moved.extent_y);

    const split = scrollPlan(0, 3, 9, .{ .start = .{ .x = 0, .y = 3 }, .end = .{ .x = 0, .y = 9 } }, 0, 0, 8, 1);
    try std.testing.expectEqual(ScrollAction.clear, split.action);

    const inactive = scrollPlan(-1, 3, 4, bounds, 0, 0, 8, 1);
    try std.testing.expectEqual(ScrollAction.none, inactive.action);
}

test "selection extend plan reports dirty range and final mode" {
    const old_bounds = Bounds{ .start = .{ .x = 1, .y = 2 }, .end = .{ .x = 3, .y = 4 } };
    const new_bounds = Bounds{ .start = .{ .x = 1, .y = 1 }, .end = .{ .x = 4, .y = 5 } };
    const plan = extendPlan(.{ .x = 3, .y = 4 }, .regular, old_bounds, .{ .x = 4, .y = 5 }, .regular, new_bounds, .ready, false);
    try std.testing.expect(plan.dirty);
    try std.testing.expectEqual(@as(i32, 1), plan.top);
    try std.testing.expectEqual(@as(i32, 5), plan.bot);
    try std.testing.expectEqual(SelectionMode.ready, plan.mode);

    const done = extendPlan(.{ .x = 3, .y = 4 }, .regular, old_bounds, .{ .x = 3, .y = 4 }, .regular, old_bounds, .ready, true);
    try std.testing.expectEqual(SelectionMode.idle, done.mode);
}

test "selection extend plan accepts unnormalized bounds" {
    const old_bounds = Bounds{ .start = .{ .x = 0, .y = 8 }, .end = .{ .x = 0, .y = 3 } };
    const new_bounds = Bounds{ .start = .{ .x = 0, .y = 6 }, .end = .{ .x = 0, .y = 1 } };
    const plan = extendPlan(.{ .x = 0, .y = 8 }, .regular, old_bounds, .{ .x = 0, .y = 6 }, .regular, new_bounds, .ready, false);

    try std.testing.expectEqual(@as(i32, 1), plan.top);
    try std.testing.expectEqual(@as(i32, 8), plan.bot);
}

test "selection normalize keeps multiline edge columns" {
    const bounds = normalize(.regular, .{ .x = 7, .y = 4 }, .{ .x = 2, .y = 9 });
    try std.testing.expectEqual(model.Point{ .x = 7, .y = 4 }, bounds.start);
    try std.testing.expectEqual(model.Point{ .x = 2, .y = 9 }, bounds.end);

    const same_line = normalize(.regular, .{ .x = 8, .y = 3 }, .{ .x = 2, .y = 3 });
    try std.testing.expectEqual(model.Point{ .x = 2, .y = 3 }, same_line.start);
    try std.testing.expectEqual(model.Point{ .x = 8, .y = 3 }, same_line.end);
}

test "selection normalize columns adjusts regular edges" {
    const bounds = normalizeColumns(.regular, .{ .start = .{ .x = 8, .y = 0 }, .end = .{ .x = 9, .y = 0 } }, 5, 9, 10);
    try std.testing.expectEqual(@as(i32, 5), bounds.start.x);
    try std.testing.expectEqual(@as(i32, 9), bounds.end.x);
}

test "selection get line plans describe output bounds" {
    const bounds = Bounds{ .start = .{ .x = 3, .y = 2 }, .end = .{ .x = 5, .y = 4 } };
    const first = getLinePlan(.regular, bounds, 2, 10);
    const middle = getLinePlan(.regular, bounds, 3, 10);
    const rectangular = getLinePlan(.rectangular, bounds, 3, 10);

    try std.testing.expectEqual(@as(i32, 3), first.start_x);
    try std.testing.expectEqual(@as(i32, 9), middle.last_x);
    try std.testing.expectEqual(@as(i32, 3), rectangular.start_x);
    try std.testing.expectEqual(@as(i32, 5), rectangular.last_x);
}

test "selection get output sizing follows wraps" {
    const bounds = Bounds{ .start = .{ .x = 0, .y = 2 }, .end = .{ .x = 0, .y = 3 } };

    try std.testing.expectEqual(@as(i32, 88), getBufferSize(10, bounds, 4));
    try std.testing.expectEqual(@as(i32, 4), getLastX(9, 5));
    try std.testing.expect(needsNewline(0, .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 0, .y = 1 } }, 3, 5, 0, .regular));
    try std.testing.expect(!needsNewline(0, .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 0, .y = 1 } }, 3, 5, model.attr_wrap, .regular));
    try std.testing.expect(needsNewline(0, .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 0, .y = 1 } }, 3, 5, model.attr_wrap, .rectangular));
}

test "selection hit test handles regular and rectangular bounds" {
    const bounds = Bounds{ .start = .{ .x = 2, .y = 1 }, .end = .{ .x = 5, .y = 4 } };
    try std.testing.expect(isSelected(.{ .x = 4, .y = 3 }, true, true, .rectangular, bounds));
    try std.testing.expect(!isSelected(.{ .x = 6, .y = 3 }, true, true, .rectangular, bounds));
    try std.testing.expect(isSelected(.{ .x = 8, .y = 2 }, true, true, .regular, bounds));
    try std.testing.expect(!isSelected(.{ .x = 1, .y = 1 }, true, true, .regular, bounds));
    try std.testing.expect(!isSelected(.{ .x = 4, .y = 3 }, false, true, .rectangular, bounds));
}

test "selection hit test accepts unnormalized bounds" {
    const bounds = Bounds{ .start = .{ .x = 5, .y = 4 }, .end = .{ .x = 2, .y = 1 } };

    try std.testing.expect(isSelected(.{ .x = 4, .y = 3 }, true, true, .rectangular, bounds));
    try std.testing.expect(isSelected(.{ .x = 8, .y = 2 }, true, true, .regular, bounds));
}

test "snap word step accepts and stops" {
    const prev = SnapPrev{ .delim = 0, .rune = 'a' };
    const accepted = snapWordStep(.{ .x = 3, .y = 2 }, 6, 0, 0, prev, 'b');
    try std.testing.expectEqual(SnapWordAction.accept, switch (accepted) {
        .accept => SnapWordAction.accept,
        .stop => SnapWordAction.stop,
    });

    const stopped = snapWordStep(.{ .x = 6, .y = 2 }, 6, 0, 0, prev, 'b');
    try std.testing.expectEqual(SnapWordAction.stop, switch (stopped) {
        .accept => SnapWordAction.accept,
        .stop => SnapWordAction.stop,
    });
}

test "snap word loop step stops on bounds and wrap" {
    const prev = SnapPrev{ .delim = 0, .rune = 'a' };
    const plan = SnapWordPlan{ .point = .{ .x = 3, .y = 2 }, .wrap_point = .{ .x = 2, .y = 2 }, .wrapped = false, .in_bounds = true };
    const accepted = snapWordLoopStep(plan, true, 6, 0, 0, prev, 'b');
    try std.testing.expectEqual(SnapWordAction.accept, switch (accepted) {
        .accept => SnapWordAction.accept,
        .stop => SnapWordAction.stop,
    });

    const out = SnapWordPlan{ .point = .{ .x = 0, .y = -1 }, .wrap_point = .{ .x = 0, .y = -1 }, .wrapped = true, .in_bounds = false };
    try std.testing.expectEqual(SnapWordAction.stop, switch (snapWordLoopStep(out, true, 6, 0, 0, prev, 'b')) {
        .accept => SnapWordAction.accept,
        .stop => SnapWordAction.stop,
    });

    const wrapped = SnapWordPlan{ .point = .{ .x = 0, .y = 3 }, .wrap_point = .{ .x = 9, .y = 2 }, .wrapped = true, .in_bounds = true };
    try std.testing.expectEqual(SnapWordAction.stop, switch (snapWordLoopStep(wrapped, false, 6, 0, 0, prev, 'b')) {
        .accept => SnapWordAction.accept,
        .stop => SnapWordAction.stop,
    });
}
