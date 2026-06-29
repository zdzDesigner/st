//! selection 领域状态机，不直接暴露 C ABI。
//! [输入]: 值类型坐标、glyph mode、delimiter 状态。
//! [输出]: selection/snap 的内部决策结果。
//! [定位]: 承载 selection 相关纯逻辑，C adapter 只负责转换 extern struct。

const std = @import("std");
const line_core = @import("st_line_core.zig");
const model = @import("term_model.zig");

pub const ZigGlyph = extern struct {
    u: u32,
    mode: c_ushort,
    fg: u32,
    bg: u32,
};

pub const ZigSelectionSnapshot = extern struct {
    mode: c_int,
    selection_type: c_int,
    alt: c_int,
    snap: c_int,
    ob_x: c_int,
    ob_y: c_int,
    oe_x: c_int,
    oe_y: c_int,
    nb_x: c_int,
    nb_y: c_int,
    ne_x: c_int,
    ne_y: c_int,
};

pub const ZigSelectionStateUpdate = extern struct {
    mode: c_int,
    selection_type: c_int,
    alt: c_int,
    snap: c_int,
    ob_x: c_int,
    ob_y: c_int,
    oe_x: c_int,
    oe_y: c_int,
    nb_x: c_int,
    nb_y: c_int,
    ne_x: c_int,
    ne_y: c_int,
};

pub const ZigSelectionEffectPlan = extern struct {
    dirty: c_int,
    top: c_int,
    bot: c_int,
    clear: c_int,
};

pub const ZigSelectionStateResult = extern struct {
    update: ZigSelectionStateUpdate,
    effect: ZigSelectionEffectPlan,
};

pub const ZigSelSnapWordPlan = extern struct {
    x: c_int,
    y: c_int,
    wrap_x: c_int,
    wrap_y: c_int,
    wrapped: c_int,
    in_bounds: c_int,
};

pub const ZigSelSnapWordStep = extern struct {
    action: c_int,
    x: c_int,
    y: c_int,
    prevdelim: c_int,
    prevrune: u32,
};

pub const ZigSelSnapWordIterRequest = extern struct {
    action: c_int,
    x: c_int,
    y: c_int,
    wrap_x: c_int,
    wrap_y: c_int,
    wrapped: c_int,
};

pub const ZigSelSnapWordReaderSnapshot = extern struct {
    wrap_allowed: c_int,
    linelen: c_int,
    mode: c_ushort,
    delim: c_int,
    rune: u32,
};

pub const ZigSelSnapWordLoopSnapshot = extern struct {
    x: c_int,
    y: c_int,
    wrap_x: c_int,
    wrap_y: c_int,
    wrapped: c_int,
    in_bounds: c_int,
    wrap_allowed: c_int,
    linelen: c_int,
    mode: c_ushort,
    delim: c_int,
    prevdelim: c_int,
    rune: u32,
    prevrune: u32,
};

pub const ZigSelSnapLineStep = extern struct {
    action: c_int,
    y: c_int,
};

pub const ZigGetSelExecPlan = extern struct {
    empty: c_int,
    start_x: c_int,
    last_index: c_int,
    newline: c_int,
    bufsize: c_int,
};

fn boolInt(value: bool) c_int {
    return if (value) 1 else 0;
}

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

pub const SelectionSnapshot = struct {
    mode: SelectionMode,
    selection_type: SelectionType,
    alt: bool,
    snap: i32,
    ob: model.Point,
    oe: model.Point,
    nb: model.Point,
    ne: model.Point,
};

pub const SelectionStateUpdate = struct {
    mode: SelectionMode,
    selection_type: SelectionType,
    alt: bool,
    snap: i32,
    ob: model.Point,
    oe: model.Point,
    nb: model.Point,
    ne: model.Point,
};

pub const SelectionStateResult = struct {
    update: SelectionStateUpdate,
    effect: SelectionEffectPlan,
};

pub const SelectionModel = struct {
    state: SelectionSnapshot,

    pub fn init(state: SelectionSnapshot) SelectionModel {
        return .{ .state = state };
    }

    pub fn start(self: SelectionModel, point: model.Point, snap: i32, alt_screen: bool) SelectionStateResult {
        return startResult(self.state, point, snap, alt_screen);
    }

    pub fn extend(self: SelectionModel, point: model.Point, selection_type: SelectionType, done: bool) SelectionStateResult {
        return extendResult(self.state, point, selection_type, done);
    }

    pub fn scroll(self: SelectionModel, scroll_origin: i32, top: i32, bot: i32, delta: i32) SelectionStateResult {
        return scrollResult(self.state, .{ .start = self.state.nb, .end = self.state.ne }, scroll_origin, top, bot, delta);
    }

    pub fn normalize(self: SelectionModel, cols: i32, start_len: i32, end_len: i32) SelectionStateResult {
        return normalizeResult(self.state, cols, start_len, end_len);
    }

    pub fn selected(self: SelectionModel, point: model.Point, alt_screen: bool) bool {
        return isSelected(point, self.state.mode != .empty and self.state.ob.x != -1, self.state.alt == alt_screen, self.state.selection_type, .{ .start = self.state.nb, .end = self.state.ne });
    }

    pub fn getSelPlan(self: SelectionModel, y: i32, cols: i32, line: []const ZigGlyph, utf_size: i32) ZigGetSelExecPlan {
        const bounds = Bounds{ .start = self.state.nb, .end = self.state.ne };
        const bufsize = getBufferSize(cols, .{ .start = .{ .x = 0, .y = self.state.nb.y }, .end = .{ .x = 0, .y = self.state.ne.y } }, utf_size);
        const linelen = (line_core.Line(ZigGlyph){ .glyphs = line, .cols = cols }).length();
        if (linelen == 0) return .{ .empty = 1, .start_x = 0, .last_index = -1, .newline = 1, .bufsize = bufsize };

        const line_plan = getLinePlan(self.state.selection_type, bounds, y, cols);
        const start_x = line_plan.start_x;
        var last_index = getLastX(line_plan.last_x, linelen);
        while (last_index >= start_x and line[@intCast(last_index)].u == ' ') {
            last_index -= 1;
        }

        const last_mode: c_ushort = if (last_index >= start_x) line[@intCast(last_index)].mode else 0;
        return .{
            .empty = if (last_index < start_x) 1 else 0,
            .start_x = start_x,
            .last_index = last_index,
            .newline = boolInt(needsNewline(y, .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 0, .y = self.state.ne.y } }, line_plan.last_x, linelen, last_mode, self.state.selection_type)),
            .bufsize = bufsize,
        };
    }
};

pub const SelectionEffectPlan = struct {
    dirty: bool,
    top: i32,
    bot: i32,
    clear: bool,
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

pub const SnapWordIterAction = enum(i32) {
    stop = 0,
    read = 1,
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

pub const SnapWordReaderSnapshot = struct {
    wrap_allowed: bool,
    linelen: i32,
    mode: u16,
    delim: i32,
    rune: model.Rune,
};

pub const SnapWordIteratorState = struct {
    point: model.Point,
    prev: SnapPrev,
    direction: i32,
    size: model.Size,
};

pub const SnapWordIterRequest = union(enum) {
    stop: SnapPrev,
    read: struct {
        plan: SnapWordPlan,
        prev: SnapPrev,
    },
};

pub const SnapWordIterResult = union(enum) {
    stop: SnapPrev,
    accept: struct {
        point: model.Point,
        prev: SnapPrev,
    },
};

pub const SnapWordIterator = struct {
    state: SnapWordIteratorState,

    pub fn request(self: SnapWordIterator) SnapWordIterRequest {
        const plan = snapWordPlan(self.state.point, self.state.direction, self.state.size);
        if (!plan.in_bounds) return .{ .stop = self.state.prev };
        return .{ .read = .{ .plan = plan, .prev = self.state.prev } };
    }

    pub fn resolve(iter_request: SnapWordIterRequest, reader: SnapWordReaderSnapshot) SnapWordIterResult {
        return switch (iter_request) {
            .stop => |prev| .{ .stop = prev },
            .read => |pending| {
                if (pending.plan.wrapped and !reader.wrap_allowed) return .{ .stop = pending.prev };
                return switch (snapWordStep(pending.plan.point, reader.linelen, reader.mode, reader.delim, pending.prev, reader.rune)) {
                    .stop => |prev| .{ .stop = prev },
                    .accept => |accepted| .{ .accept = .{ .point = accepted.point, .prev = accepted.prev } },
                };
            },
        };
    }
};

pub fn zigSelsnapworditerrequest(x: c_int, y: c_int, direction: c_int, col: c_int, row: c_int, prevdelim: c_int, prevrune: u32) ZigSelSnapWordIterRequest {
    const request = (SnapWordIterator{ .state = .{
        .point = .{ .x = x, .y = y },
        .prev = .{ .delim = prevdelim, .rune = prevrune },
        .direction = direction,
        .size = .{ .cols = col, .rows = row },
    } }).request();
    return switch (request) {
        .stop => .{
            .action = @intFromEnum(SnapWordIterAction.stop),
            .x = x,
            .y = y,
            .wrap_x = x,
            .wrap_y = y,
            .wrapped = 0,
        },
        .read => |pending| .{
            .action = @intFromEnum(SnapWordIterAction.read),
            .x = pending.plan.point.x,
            .y = pending.plan.point.y,
            .wrap_x = pending.plan.wrap_point.x,
            .wrap_y = pending.plan.wrap_point.y,
            .wrapped = boolInt(pending.plan.wrapped),
        },
    };
}

pub fn zigSelsnapworditerresolve(request: ZigSelSnapWordIterRequest, prevdelim: c_int, prevrune: u32, reader: ZigSelSnapWordReaderSnapshot) ZigSelSnapWordStep {
    const iter_request: SnapWordIterRequest = if (request.action == @intFromEnum(SnapWordIterAction.read))
        .{ .read = .{ .plan = .{
            .point = .{ .x = request.x, .y = request.y },
            .wrap_point = .{ .x = request.wrap_x, .y = request.wrap_y },
            .wrapped = request.wrapped != 0,
            .in_bounds = true,
        }, .prev = .{ .delim = prevdelim, .rune = prevrune } } }
    else
        .{ .stop = .{ .delim = prevdelim, .rune = prevrune } };

    const result = SnapWordIterator.resolve(iter_request, .{
        .wrap_allowed = reader.wrap_allowed != 0,
        .linelen = reader.linelen,
        .mode = reader.mode,
        .delim = reader.delim,
        .rune = reader.rune,
    });
    return switch (result) {
        .stop => |prev| .{ .action = @intFromEnum(SnapWordAction.stop), .x = request.x, .y = request.y, .prevdelim = prev.delim, .prevrune = prev.rune },
        .accept => |accepted| .{ .action = @intFromEnum(SnapWordAction.accept), .x = accepted.point.x, .y = accepted.point.y, .prevdelim = accepted.prev.delim, .prevrune = accepted.prev.rune },
    };
}

pub const SnapWordLoop = struct {
    plan: SnapWordPlan,
    wrap_allowed: bool,
    linelen: i32,
    mode: u16,
    delim: i32,
    prev: SnapPrev,
    rune: model.Rune,

    pub fn fromZig(snapshot: ZigSelSnapWordLoopSnapshot) SnapWordLoop {
        return .{
            .plan = .{
                .point = .{ .x = snapshot.x, .y = snapshot.y },
                .wrap_point = .{ .x = snapshot.wrap_x, .y = snapshot.wrap_y },
                .wrapped = snapshot.wrapped != 0,
                .in_bounds = snapshot.in_bounds != 0,
            },
            .wrap_allowed = snapshot.wrap_allowed != 0,
            .linelen = snapshot.linelen,
            .mode = snapshot.mode,
            .delim = snapshot.delim,
            .prev = .{ .delim = snapshot.prevdelim, .rune = snapshot.prevrune },
            .rune = snapshot.rune,
        };
    }

    pub fn step(self: SnapWordLoop) SnapWordLoopStep {
        return switch (SnapWordIterator.resolve(if (!self.plan.in_bounds)
            .{ .stop = self.prev }
        else
            .{ .read = .{ .plan = self.plan, .prev = self.prev } }, .{
            .wrap_allowed = self.wrap_allowed,
            .linelen = self.linelen,
            .mode = self.mode,
            .delim = self.delim,
            .rune = self.rune,
        })) {
            .stop => |prev| .{ .stop = prev },
            .accept => |accepted| .{ .accept = .{ .point = accepted.point, .prev = accepted.prev } },
        };
    }
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

pub fn startResult(snapshot: SelectionSnapshot, point: model.Point, snap: i32, alt_screen: bool) SelectionStateResult {
    const plan = startPlan(point, snap, alt_screen);
    return .{
        .update = .{
            .mode = plan.mode,
            .selection_type = plan.selection_type,
            .alt = plan.alt,
            .snap = plan.snap,
            .ob = point,
            .oe = point,
            .nb = point,
            .ne = point,
        },
        .effect = .{
            .dirty = snapshot.mode != plan.mode or snapshot.selection_type != plan.selection_type or snapshot.snap != plan.snap,
            .top = point.y,
            .bot = point.y,
            .clear = false,
        },
    };
}

pub fn extendResult(snapshot: SelectionSnapshot, new_point: model.Point, new_type: SelectionType, done: bool) SelectionStateResult {
    const old_bounds = Bounds{ .start = snapshot.nb, .end = snapshot.ne };
    const new_bounds = normalize(new_type, snapshot.ob, new_point);
    const plan = extendPlan(snapshot.oe, snapshot.selection_type, old_bounds, new_point, new_type, new_bounds, snapshot.mode, done);
    return .{
        .update = .{
            .mode = plan.mode,
            .selection_type = new_type,
            .alt = snapshot.alt,
            .snap = snapshot.snap,
            .ob = snapshot.ob,
            .oe = new_point,
            .nb = new_bounds.start,
            .ne = new_bounds.end,
        },
        .effect = .{ .dirty = plan.dirty, .top = plan.top, .bot = plan.bot, .clear = done and plan.mode == .idle },
    };
}

pub fn scrollResult(snapshot: SelectionSnapshot, bounds: Bounds, scroll_origin: i32, top: i32, bot: i32, delta: i32) SelectionStateResult {
    const plan = scrollPlan(snapshot.ob.x, snapshot.ob.y, snapshot.oe.y, bounds, scroll_origin, top, bot, delta);
    const next_ob_y = switch (plan.action) {
        .none => snapshot.ob.y,
        .clear => snapshot.ob.y,
        .normalize => plan.origin_y,
    };
    const next_oe_y = switch (plan.action) {
        .none => snapshot.oe.y,
        .clear => snapshot.oe.y,
        .normalize => plan.extent_y,
    };
    return .{
        .update = .{
            .mode = if (plan.action == .clear) .idle else snapshot.mode,
            .selection_type = snapshot.selection_type,
            .alt = snapshot.alt,
            .snap = snapshot.snap,
            .ob = .{ .x = snapshot.ob.x, .y = next_ob_y },
            .oe = .{ .x = snapshot.oe.x, .y = next_oe_y },
            .nb = snapshot.nb,
            .ne = snapshot.ne,
        },
        .effect = .{
            .dirty = plan.action != .none,
            .top = plan.origin_y,
            .bot = plan.extent_y,
            .clear = plan.action == .clear,
        },
    };
}

pub fn normalizeResult(snapshot: SelectionSnapshot, cols: i32, start_len: i32, end_len: i32) SelectionStateResult {
    var bounds = normalize(snapshot.selection_type, snapshot.ob, snapshot.oe);
    if (snapshot.selection_type != .rectangular) {
        bounds = normalizeColumns(snapshot.selection_type, bounds, start_len, end_len, cols);
    }
    return .{
        .update = .{
            .mode = snapshot.mode,
            .selection_type = snapshot.selection_type,
            .alt = snapshot.alt,
            .snap = snapshot.snap,
            .ob = snapshot.ob,
            .oe = snapshot.oe,
            .nb = bounds.start,
            .ne = bounds.end,
        },
        .effect = .{
            .dirty = false,
            .top = bounds.start.y,
            .bot = bounds.end.y,
            .clear = false,
        },
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

pub fn zigSelectionMode(value: c_int) SelectionMode {
    if (value == @intFromEnum(SelectionMode.empty)) return .empty;
    if (value == 0) return .idle;
    return .ready;
}

pub fn zigSelectionType(value: c_int) SelectionType {
    return if (value == @intFromEnum(SelectionType.rectangular)) .rectangular else .regular;
}

pub fn zigSelectionSnapshot(snapshot: ZigSelectionSnapshot) SelectionSnapshot {
    return .{
        .mode = zigSelectionMode(snapshot.mode),
        .selection_type = zigSelectionType(snapshot.selection_type),
        .alt = snapshot.alt != 0,
        .snap = snapshot.snap,
        .ob = .{ .x = snapshot.ob_x, .y = snapshot.ob_y },
        .oe = .{ .x = snapshot.oe_x, .y = snapshot.oe_y },
        .nb = .{ .x = snapshot.nb_x, .y = snapshot.nb_y },
        .ne = .{ .x = snapshot.ne_x, .y = snapshot.ne_y },
    };
}

pub fn zigSelectionStateResult(result: SelectionStateResult) ZigSelectionStateResult {
    return .{
        .update = .{
            .mode = @intFromEnum(result.update.mode),
            .selection_type = @intFromEnum(result.update.selection_type),
            .alt = boolInt(result.update.alt),
            .snap = result.update.snap,
            .ob_x = result.update.ob.x,
            .ob_y = result.update.ob.y,
            .oe_x = result.update.oe.x,
            .oe_y = result.update.oe.y,
            .nb_x = result.update.nb.x,
            .nb_y = result.update.nb.y,
            .ne_x = result.update.ne.x,
            .ne_y = result.update.ne.y,
        },
        .effect = .{
            .dirty = boolInt(result.effect.dirty),
            .top = result.effect.top,
            .bot = result.effect.bot,
            .clear = boolInt(result.effect.clear),
        },
    };
}

pub fn zigSelclearplan(ob_x: c_int) c_int {
    return boolInt(shouldClear(ob_x));
}

export fn st_selclearplan(ob_x: c_int) c_int {
    return zigSelclearplan(ob_x);
}

pub fn zigSelstartupdate(snapshot: ZigSelectionSnapshot, col: c_int, row: c_int, snap: c_int, alt_screen: c_int) ZigSelectionStateResult {
    return zigSelectionStateResult(SelectionModel.init(zigSelectionSnapshot(snapshot)).start(.{ .x = col, .y = row }, snap, alt_screen != 0));
}

export fn st_selstartupdate(snapshot: ZigSelectionSnapshot, col: c_int, row: c_int, snap: c_int, alt_screen: c_int) ZigSelectionStateResult {
    return zigSelstartupdate(snapshot, col, row, snap, alt_screen);
}

pub fn zigSelextendupdate(snapshot: ZigSelectionSnapshot, col: c_int, row: c_int, sel_type: c_int, done: c_int) ZigSelectionStateResult {
    return zigSelectionStateResult(SelectionModel.init(zigSelectionSnapshot(snapshot)).extend(.{ .x = col, .y = row }, zigSelectionType(sel_type), done != 0));
}

export fn st_selextendupdate(snapshot: ZigSelectionSnapshot, col: c_int, row: c_int, sel_type: c_int, done: c_int) ZigSelectionStateResult {
    return zigSelextendupdate(snapshot, col, row, sel_type, done);
}

pub fn zigSelscrollupdate(snapshot: ZigSelectionSnapshot, orig: c_int, top: c_int, bot: c_int, delta: c_int) ZigSelectionStateResult {
    return zigSelectionStateResult(SelectionModel.init(zigSelectionSnapshot(snapshot)).scroll(orig, top, bot, delta));
}

export fn st_selscrollupdate(snapshot: ZigSelectionSnapshot, orig: c_int, top: c_int, bot: c_int, delta: c_int) ZigSelectionStateResult {
    return zigSelscrollupdate(snapshot, orig, top, bot, delta);
}

pub fn zigSelnormalizeupdate(snapshot: ZigSelectionSnapshot, col: c_int, start_len: c_int, end_len: c_int) ZigSelectionStateResult {
    return zigSelectionStateResult(SelectionModel.init(zigSelectionSnapshot(snapshot)).normalize(col, start_len, end_len));
}

export fn st_selnormalizeupdate(snapshot: ZigSelectionSnapshot, col: c_int, start_len: c_int, end_len: c_int) ZigSelectionStateResult {
    return zigSelnormalizeupdate(snapshot, col, start_len, end_len);
}

pub fn zigSelsnaplinestep(y: c_int, direction: c_int, row: c_int, wrapped: c_int) ZigSelSnapLineStep {
    return switch (snapLineStep(y, direction, row, wrapped != 0)) {
        .stop => |next_y| .{ .action = @intFromEnum(SnapLineAction.stop), .y = next_y },
        .move => |next_y| .{ .action = @intFromEnum(SnapLineAction.move), .y = next_y },
    };
}

export fn st_selsnaplinex(direction: c_int, col: c_int) c_int {
    return snapLineX(direction, col);
}

export fn st_selsnaplinestep(y: c_int, direction: c_int, row: c_int, wrapped: c_int) ZigSelSnapLineStep {
    return zigSelsnaplinestep(y, direction, row, wrapped);
}

export fn st_selsnapworditerrequest(x: c_int, y: c_int, direction: c_int, col: c_int, row: c_int, prevdelim: c_int, prevrune: u32) ZigSelSnapWordIterRequest {
    return zigSelsnapworditerrequest(x, y, direction, col, row, prevdelim, prevrune);
}

export fn st_selsnapworditerresolve(request: ZigSelSnapWordIterRequest, prevdelim: c_int, prevrune: u32, reader: ZigSelSnapWordReaderSnapshot) ZigSelSnapWordStep {
    return zigSelsnapworditerresolve(request, prevdelim, prevrune, reader);
}

pub fn zigSelsnapwordplan(x: c_int, y: c_int, direction: c_int, col: c_int, row: c_int) ZigSelSnapWordPlan {
    const plan = snapWordPlan(.{ .x = x, .y = y }, direction, .{ .cols = col, .rows = row });
    return .{ .x = plan.point.x, .y = plan.point.y, .wrap_x = plan.wrap_point.x, .wrap_y = plan.wrap_point.y, .wrapped = boolInt(plan.wrapped), .in_bounds = boolInt(plan.in_bounds) };
}

pub fn zigSelsnapwordloopstep(snapshot: ZigSelSnapWordLoopSnapshot) ZigSelSnapWordStep {
    const step = SnapWordLoop.fromZig(snapshot).step();
    return switch (step) {
        .stop => |prev| .{ .action = @intFromEnum(SnapWordAction.stop), .x = snapshot.x, .y = snapshot.y, .prevdelim = prev.delim, .prevrune = prev.rune },
        .accept => |accepted| .{ .action = @intFromEnum(SnapWordAction.accept), .x = accepted.point.x, .y = accepted.point.y, .prevdelim = accepted.prev.delim, .prevrune = accepted.prev.rune },
    };
}

pub fn zigSelected(snapshot: ZigSelectionSnapshot, x: c_int, y: c_int, alt_screen: c_int) c_int {
    return boolInt(SelectionModel.init(zigSelectionSnapshot(snapshot)).selected(.{ .x = x, .y = y }, alt_screen != 0));
}

export fn st_selected(snapshot: ZigSelectionSnapshot, x: c_int, y: c_int, alt_screen: c_int) c_int {
    return zigSelected(snapshot, x, y, alt_screen);
}

pub fn zigGetselexecplan(snapshot: ZigSelectionSnapshot, y: c_int, col: c_int, line: [*]const ZigGlyph, utf_siz: c_int) ZigGetSelExecPlan {
    return SelectionModel.init(zigSelectionSnapshot(snapshot)).getSelPlan(y, col, line[0..@intCast(col)], utf_siz);
}

export fn st_getselexecplan(snapshot: ZigSelectionSnapshot, y: c_int, col: c_int, line: [*]const ZigGlyph, utf_siz: c_int) ZigGetSelExecPlan {
    return zigGetselexecplan(snapshot, y, col, line, utf_siz);
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
    return switch (SnapWordIterator.resolve(if (!plan.in_bounds)
        .{ .stop = prev }
    else
        .{ .read = .{ .plan = plan, .prev = prev } }, .{
        .wrap_allowed = wrap_allowed,
        .linelen = linelen,
        .mode = mode,
        .delim = delim,
        .rune = rune,
    })) {
        .stop => |stopped| .{ .stop = stopped },
        .accept => |accepted| .{ .accept = .{ .point = accepted.point, .prev = accepted.prev } },
    };
}

fn between(value: i32, lower: i32, upper: i32) bool {
    return lower <= value and value <= upper;
}

fn testSelectionSnapshot(selection_type: SelectionType, mode: SelectionMode, alt: bool, ob_x: i32, nb: model.Point, ne: model.Point) ZigSelectionSnapshot {
    return .{
        .mode = @intFromEnum(mode),
        .selection_type = @intFromEnum(selection_type),
        .alt = boolInt(alt),
        .snap = 0,
        .ob_x = ob_x,
        .ob_y = nb.y,
        .oe_x = ne.x,
        .oe_y = ne.y,
        .nb_x = nb.x,
        .nb_y = nb.y,
        .ne_x = ne.x,
        .ne_y = ne.y,
    };
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

test "selection state adapter exports smoke tests" {
    const scroll = st_selscrollupdate(testSelectionSnapshot(.regular, .ready, false, 0, .{ .x = 0, .y = 2 }, .{ .x = 3, .y = 6 }), 4, 0, 9, 1);
    try std.testing.expectEqual(@as(c_int, 1), scroll.effect.clear);

    const extend = st_selextendupdate(testSelectionSnapshot(.regular, .empty, false, 1, .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 }), 3, 5, @intFromEnum(SelectionType.rectangular), 0);
    try std.testing.expectEqual(@as(c_int, 1), extend.effect.dirty);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SelectionMode.ready)), extend.update.mode);

    const start = st_selstartupdate(testSelectionSnapshot(.regular, .idle, false, -1, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 }), 3, 4, 1, 1);
    try std.testing.expectEqual(@as(c_int, 1), start.effect.dirty);
}

test "selection clear and line snap adapter exports" {
    try std.testing.expectEqual(@as(c_int, 0), st_selclearplan(-1));
    try std.testing.expectEqual(@as(c_int, 1), st_selclearplan(0));
    try std.testing.expectEqual(@as(c_int, 0), st_selsnaplinex(-1, 10));
    try std.testing.expectEqual(@as(c_int, 9), st_selsnaplinex(1, 10));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SnapLineAction.move)), st_selsnaplinestep(3, -1, 5, 1).action);
    try std.testing.expectEqual(@as(c_int, 2), st_selsnaplinestep(3, -1, 5, 1).y);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SnapLineAction.stop)), st_selsnaplinestep(3, 1, 5, 0).action);
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

test "selection hit test adapter smoke test" {
    const regular = testSelectionSnapshot(.regular, .ready, false, 0, .{ .x = 1, .y = 2 }, .{ .x = 5, .y = 2 });
    try std.testing.expectEqual(@as(c_int, 1), st_selected(regular, 3, 2, 0));

    const rectangular = testSelectionSnapshot(.rectangular, .ready, false, 0, .{ .x = 2, .y = 1 }, .{ .x = 5, .y = 4 });
    try std.testing.expectEqual(@as(c_int, 1), st_selected(rectangular, 4, 3, 0));

    const inactive = testSelectionSnapshot(.regular, .empty, false, 0, .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 2 });
    try std.testing.expectEqual(@as(c_int, 0), st_selected(inactive, 1, 1, 0));

    const alt_mismatch = testSelectionSnapshot(.regular, .ready, true, 0, .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 2 });
    try std.testing.expectEqual(@as(c_int, 0), st_selected(alt_mismatch, 1, 1, 0));
}

test "get selection exec plan adapter smoke test" {
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
    const snapshot = testSelectionSnapshot(.regular, .ready, false, 0, .{ .x = 3, .y = 2 }, .{ .x = 5, .y = 4 });
    const first = st_getselexecplan(snapshot, 2, line.len, &line, 4);
    const middle = st_getselexecplan(snapshot, 3, line.len, &line, 4);

    try std.testing.expectEqual(@as(c_int, 3), first.start_x);
    try std.testing.expectEqual(@as(c_int, 1), first.newline);
    try std.testing.expectEqual(@as(c_int, 0), middle.start_x);
}

test "get selection exec plan adapter keeps rectangular and wrap behaviour" {
    const rect_line = [_]ZigGlyph{
        .{ .u = '甲', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '乙', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '丙', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '丁', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '戊', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = '己', .mode = 0, .fg = 0, .bg = 0 },
    };
    const rect = st_getselexecplan(testSelectionSnapshot(.rectangular, .ready, false, 0, .{ .x = 3, .y = 2 }, .{ .x = 5, .y = 4 }), 3, rect_line.len, &rect_line, 4);
    try std.testing.expectEqual(@as(c_int, 3), rect.start_x);

    const empty = [_]ZigGlyph{ .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 }, .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 }, .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 }, .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 }, .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 }, .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 }, .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 }, .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 }, .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 }, .{ .u = ' ', .mode = 0, .fg = 0, .bg = 0 } };
    const empty_plan = st_getselexecplan(testSelectionSnapshot(.regular, .ready, false, 0, .{ .x = 0, .y = 2 }, .{ .x = 0, .y = 3 }), 2, empty.len, &empty, 4);
    try std.testing.expectEqual(@as(c_int, 1), empty_plan.empty);

    const wrapped = [_]ZigGlyph{ .{ .u = '甲', .mode = 0, .fg = 0, .bg = 0 }, .{ .u = '乙', .mode = model.attr_wrap, .fg = 0, .bg = 0 } };
    const wrapped_regular = st_getselexecplan(testSelectionSnapshot(.regular, .ready, false, 0, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 }), 0, wrapped.len, &wrapped, 4);
    const wrapped_rect = st_getselexecplan(testSelectionSnapshot(.rectangular, .ready, false, 0, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 }), 0, wrapped.len, &wrapped, 4);
    try std.testing.expectEqual(@as(c_int, 0), wrapped_regular.newline);
    try std.testing.expectEqual(@as(c_int, 1), wrapped_rect.newline);
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

test "snap word iterator requests next point and updates previous glyph" {
    const request = (SnapWordIterator{ .state = .{
        .point = .{ .x = 2, .y = 2 },
        .prev = .{ .delim = 0, .rune = 'a' },
        .direction = 1,
        .size = .{ .cols = 10, .rows = 5 },
    } }).request();

    switch (request) {
        .stop => try std.testing.expect(false),
        .read => |pending| {
            try std.testing.expectEqual(model.Point{ .x = 3, .y = 2 }, pending.plan.point);
            const result = SnapWordIterator.resolve(request, .{
                .wrap_allowed = true,
                .linelen = 6,
                .mode = 0,
                .delim = 0,
                .rune = 'b',
            });
            switch (result) {
                .stop => try std.testing.expect(false),
                .accept => |accepted| {
                    try std.testing.expectEqual(model.Point{ .x = 3, .y = 2 }, accepted.point);
                    try std.testing.expectEqual(@as(i32, 0), accepted.prev.delim);
                    try std.testing.expectEqual(@as(model.Rune, 'b'), accepted.prev.rune);
                },
            }
        },
    }
}

test "zig snap word iterator adapter returns read request" {
    const request = zigSelsnapworditerrequest(2, 2, 1, 10, 5, 0, 'a');
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SnapWordIterAction.read)), request.action);
    try std.testing.expectEqual(@as(c_int, 3), request.x);
    try std.testing.expectEqual(@as(c_int, 2), request.y);
}

test "zig snap word iterator adapter resolves reader facts" {
    const request = zigSelsnapworditerrequest(2, 2, 1, 10, 5, 0, 'a');
    const step = zigSelsnapworditerresolve(request, 0, 'a', .{
        .wrap_allowed = 1,
        .linelen = 6,
        .mode = 0,
        .delim = 0,
        .rune = 'b',
    });
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SnapWordAction.accept)), step.action);
    try std.testing.expectEqual(@as(c_int, 3), step.x);
    try std.testing.expectEqual(@as(u32, 'b'), step.prevrune);
}

test "snap word iterator stops on delimiter change after accept" {
    const size = model.Size{ .cols = 10, .rows = 5 };
    const first_request = (SnapWordIterator{ .state = .{
        .point = .{ .x = 2, .y = 2 },
        .prev = .{ .delim = 0, .rune = 'a' },
        .direction = 1,
        .size = size,
    } }).request();
    const first_result = SnapWordIterator.resolve(first_request, .{
        .wrap_allowed = true,
        .linelen = 6,
        .mode = 0,
        .delim = 0,
        .rune = 'b',
    });

    const accepted = switch (first_result) {
        .accept => |value| value,
        .stop => unreachable,
    };

    const second_request = (SnapWordIterator{ .state = .{
        .point = accepted.point,
        .prev = accepted.prev,
        .direction = 1,
        .size = size,
    } }).request();
    const second_result = SnapWordIterator.resolve(second_request, .{
        .wrap_allowed = true,
        .linelen = 6,
        .mode = 0,
        .delim = 1,
        .rune = ',',
    });

    switch (second_result) {
        .accept => try std.testing.expect(false),
        .stop => |prev| {
            try std.testing.expectEqual(@as(i32, 0), prev.delim);
            try std.testing.expectEqual(@as(model.Rune, 'b'), prev.rune);
        },
    }
}

test "snap word iterator stops on wrapped read when wrap is disallowed" {
    const request = (SnapWordIterator{ .state = .{
        .point = .{ .x = 9, .y = 2 },
        .prev = .{ .delim = 0, .rune = 'a' },
        .direction = 1,
        .size = .{ .cols = 10, .rows = 5 },
    } }).request();

    switch (request) {
        .stop => try std.testing.expect(false),
        .read => |pending| {
            try std.testing.expect(pending.plan.wrapped);
            try std.testing.expectEqual(model.Point{ .x = 0, .y = 3 }, pending.plan.point);
        },
    }

    const result = SnapWordIterator.resolve(request, .{
        .wrap_allowed = false,
        .linelen = 6,
        .mode = 0,
        .delim = 0,
        .rune = 'b',
    });
    switch (result) {
        .accept => try std.testing.expect(false),
        .stop => |prev| {
            try std.testing.expectEqual(@as(i32, 0), prev.delim);
            try std.testing.expectEqual(@as(model.Rune, 'a'), prev.rune);
        },
    }
}

test "snap word iterator stops immediately when next point is out of bounds" {
    const request = (SnapWordIterator{ .state = .{
        .point = .{ .x = 0, .y = 0 },
        .prev = .{ .delim = 0, .rune = 'a' },
        .direction = -1,
        .size = .{ .cols = 10, .rows = 5 },
    } }).request();

    switch (request) {
        .read => unreachable,
        .stop => |prev| {
            try std.testing.expectEqual(@as(i32, 0), prev.delim);
            try std.testing.expectEqual(@as(model.Rune, 'a'), prev.rune);
        },
    }
}

test "snap word loop module converts C snapshot" {
    const loop = SnapWordLoop.fromZig(.{
        .x = 3,
        .y = 2,
        .wrap_x = 2,
        .wrap_y = 2,
        .wrapped = 0,
        .in_bounds = 1,
        .wrap_allowed = 1,
        .linelen = 6,
        .mode = 0,
        .delim = 0,
        .prevdelim = 0,
        .rune = 'b',
        .prevrune = 'a',
    });

    const step = loop.step();
    try std.testing.expectEqual(SnapWordAction.accept, switch (step) {
        .accept => SnapWordAction.accept,
        .stop => SnapWordAction.stop,
    });
}
