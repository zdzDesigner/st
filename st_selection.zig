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

pub const SnapWordPlan = struct {
    point: model.Point,
    wrap_point: model.Point,
    wrapped: bool,
    in_bounds: bool,
};

pub const SnapWordAction = enum(i32) {
    stop = 0,
    accept = 1,
};

pub const SnapWordStep = union(enum) {
    stop: SnapPrev,
    accept: struct {
        point: model.Point,
        prev: SnapPrev,
    },
};

pub fn snapLineX(direction: i32, col: i32) i32 {
    return if (direction < 0) 0 else col - 1;
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

pub fn isSelected(point: model.Point, active: bool, alt_matches: bool, selection_type: SelectionType, bounds: Bounds) bool {
    if (!active or !alt_matches) return false;

    return switch (selection_type) {
        .rectangular => between(point.y, bounds.start.y, bounds.end.y) and between(point.x, bounds.start.x, bounds.end.x),
        .regular => between(point.y, bounds.start.y, bounds.end.y) and (point.y != bounds.start.y or point.x >= bounds.start.x) and (point.y != bounds.end.y or point.x <= bounds.end.x),
    };
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

test "selection hit test handles regular and rectangular bounds" {
    const bounds = Bounds{ .start = .{ .x = 2, .y = 1 }, .end = .{ .x = 5, .y = 4 } };
    try std.testing.expect(isSelected(.{ .x = 4, .y = 3 }, true, true, .rectangular, bounds));
    try std.testing.expect(!isSelected(.{ .x = 6, .y = 3 }, true, true, .rectangular, bounds));
    try std.testing.expect(isSelected(.{ .x = 8, .y = 2 }, true, true, .regular, bounds));
    try std.testing.expect(!isSelected(.{ .x = 1, .y = 1 }, true, true, .regular, bounds));
    try std.testing.expect(!isSelected(.{ .x = 4, .y = 3 }, false, true, .rectangular, bounds));
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
