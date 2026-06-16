//! line 领域纯逻辑，不直接暴露 C ABI。
//! [输入]: glyph 行、tab stops、行列尺寸和属性 mask。
//! [输出]: 行长度、tab 目标、dirty 范围、dump/external pipe 计划和属性扫描结果。
//! [定位]: 承载行级纯逻辑，`st_line.zig` 只保留 C ABI adapter。

const std = @import("std");
const model = @import("term_model.zig");

pub const DumpLinePlan = struct {
    write: bool,
    last: i32,
};

pub const LineRange = struct {
    top: i32,
    bot: i32,
};

pub const ExternalPipeLineKind = enum(i32) {
    break_line = 0,
    skip = 1,
    write = 2,
};

pub const ExternalPipeLinePlan = struct {
    kind: ExternalPipeLineKind,
    lastpos: i32,
};

pub fn Line(comptime Glyph: type) type {
    return struct {
        glyphs: []const Glyph,
        cols: i32,

        const Self = @This();

        pub fn length(self: Self) i32 {
            var end = self.cols;

            if (model.hasWrap(self.glyphs[@intCast(end - 1)].mode)) return end;

            while (end > 0 and self.glyphs[@intCast(end - 1)].u == ' ') {
                end -= 1;
            }

            return end;
        }

        pub fn hasAttr(self: Self, mask: u16) bool {
            var x: i32 = 0;
            while (x < self.cols - 1) : (x += 1) {
                if ((self.glyphs[@intCast(x)].mode & mask) != 0) return true;
            }
            return false;
        }
    };
}

pub const TabStops = struct {
    stops: []const i32,
    cols: i32,

    pub fn target(self: TabStops, x: i32, count: i32) i32 {
        var next_x = x;

        if (count > 0) {
            var remaining = count;
            while (next_x < self.cols and remaining > 0) : (remaining -= 1) {
                next_x += 1;
                while (next_x < self.cols and self.stops[@intCast(next_x)] == 0) {
                    next_x += 1;
                }
            }
        } else if (count < 0) {
            var remaining = count;
            while (next_x > 0 and remaining < 0) : (remaining += 1) {
                next_x -= 1;
                while (next_x > 0 and self.stops[@intCast(next_x)] == 0) {
                    next_x -= 1;
                }
            }
        }

        return limitInt(next_x, 0, self.cols - 1);
    }
};

pub fn Lines(comptime Glyph: type) type {
    return struct {
        rows: []const [*]const Glyph,
        row_count: i32,
        cols: i32,

        const Self = @This();

        pub fn hasAttr(self: Self, mask: u16) bool {
            var y: i32 = 0;
            while (y < self.row_count - 1) : (y += 1) {
                const line = Line(Glyph){ .glyphs = self.rows[@intCast(y)][0..@intCast(self.cols)], .cols = self.cols };
                if (line.hasAttr(mask)) return true;
            }
            return false;
        }
    };
}

pub const VisualLine = struct {
    len: i32,
    cols: i32,

    pub fn dump(self: VisualLine) DumpLinePlan {
        const end = minInt(self.len, self.cols);
        return .{
            .write = end > 0,
            .last = end - 1,
        };
    }

    pub fn externalPipe(self: VisualLine) ExternalPipeLinePlan {
        const lastpos = minInt(self.len + 1, self.cols) - 1;
        if (lastpos < 0) return .{ .kind = .break_line, .lastpos = lastpos };
        if (lastpos == 0) return .{ .kind = .skip, .lastpos = lastpos };
        return .{ .kind = .write, .lastpos = lastpos };
    }
};

pub const Viewport = struct {
    rows: i32,

    pub fn dirtyRange(self: Viewport, top: i32, bot: i32) LineRange {
        return .{
            .top = limitInt(top, 0, self.rows - 1),
            .bot = limitInt(bot, 0, self.rows - 1),
        };
    }
};

pub fn lineLen(comptime Glyph: type, line: []const Glyph, cols: i32) i32 {
    return (Line(Glyph){ .glyphs = line, .cols = cols }).length();
}

pub fn tabTarget(x: i32, cols: i32, count: i32, tabs: []const i32) i32 {
    return (TabStops{ .stops = tabs, .cols = cols }).target(x, count);
}

pub fn attrSet(comptime Glyph: type, lines: []const [*]const Glyph, rows: i32, cols: i32, mask: u16) bool {
    return (Lines(Glyph){ .rows = lines, .row_count = rows, .cols = cols }).hasAttr(mask);
}

pub fn lineAttrSet(comptime Glyph: type, line: [*]const Glyph, cols: i32, mask: u16) bool {
    return (Line(Glyph){ .glyphs = line[0..@intCast(cols)], .cols = cols }).hasAttr(mask);
}

pub fn dumpLinePlan(linelen: i32, cols: i32) DumpLinePlan {
    return (VisualLine{ .len = linelen, .cols = cols }).dump();
}

pub fn dirtyRange(top: i32, bot: i32, rows: i32) LineRange {
    return (Viewport{ .rows = rows }).dirtyRange(top, bot);
}

pub fn externalPipeLine(linelen: i32, cols: i32) ExternalPipeLinePlan {
    return (VisualLine{ .len = linelen, .cols = cols }).externalPipe();
}

pub fn externalPipeWrap(mode: u16) bool {
    return model.hasWrap(mode);
}

fn minInt(a: i32, b: i32) i32 {
    return if (a < b) a else b;
}

fn limitInt(value: i32, lower: i32, upper: i32) i32 {
    if (value < lower) return lower;
    if (value > upper) return upper;
    return value;
}

test "line core trims spaces and preserves wraps" {
    const Glyph = struct { u: u32, mode: u16 };
    const plain = [_]Glyph{
        .{ .u = '你', .mode = 0 },
        .{ .u = '好', .mode = 0 },
        .{ .u = ' ', .mode = 0 },
    };
    const wrapped = [_]Glyph{
        .{ .u = '中', .mode = 0 },
        .{ .u = ' ', .mode = model.attr_wrap },
    };

    try std.testing.expectEqual(@as(i32, 2), lineLen(Glyph, &plain, plain.len));
    try std.testing.expectEqual(@as(i32, 2), lineLen(Glyph, &wrapped, wrapped.len));
}

test "line core tab movement and ranges" {
    const tabs = [_]i32{ 0, 0, 0, 0, 1, 0, 0, 0, 1, 0 };

    try std.testing.expectEqual(@as(i32, 4), tabTarget(2, tabs.len, 1, &tabs));
    try std.testing.expectEqual(@as(i32, 4), tabTarget(7, tabs.len, -1, &tabs));
    try std.testing.expectEqual(@as(i32, 0), dirtyRange(-2, 99, 24).top);
    try std.testing.expectEqual(@as(i32, 23), dirtyRange(-2, 99, 24).bot);
}

test "line core scans attributes before excluded edge" {
    const Glyph = struct { u: u32, mode: u16 };
    var row0 = [_]Glyph{ .{ .u = '中', .mode = 0 }, .{ .u = '文', .mode = 1 << 3 }, .{ .u = '边', .mode = 0 } };
    var row1 = [_]Glyph{ .{ .u = '界', .mode = 0 }, .{ .u = '测', .mode = 0 }, .{ .u = '试', .mode = 0 } };
    const lines = [_][*]const Glyph{ &row0, &row1 };

    try std.testing.expect(attrSet(Glyph, &lines, 2, 3, 1 << 3));
    try std.testing.expect(lineAttrSet(Glyph, &row0, 3, 1 << 3));
    try std.testing.expect(!lineAttrSet(Glyph, &row0, 3, 1 << 4));
}

test "line core dump and external pipe plans" {
    try std.testing.expect(dumpLinePlan(3, 10).write);
    try std.testing.expectEqual(@as(i32, 2), dumpLinePlan(3, 10).last);
    try std.testing.expect(!dumpLinePlan(0, 10).write);
    try std.testing.expectEqual(ExternalPipeLineKind.break_line, externalPipeLine(-1, 10).kind);
    try std.testing.expectEqual(ExternalPipeLineKind.skip, externalPipeLine(0, 10).kind);
    try std.testing.expectEqual(ExternalPipeLineKind.write, externalPipeLine(3, 10).kind);
    try std.testing.expect(externalPipeWrap(model.attr_wrap));
    try std.testing.expect(!externalPipeWrap(0));
}
