//! st_color_core.zig 是 SGR truecolor/indexed color 参数解析核心。
//! [输入]: SGR 参数切片和当前参数下标 `npar`。
//! [输出]: `ZigColorParse`，包含颜色索引、下一参数位置和具体错误上下文。
//! [副作用边界]: 不打印错误、不修改 terminal 属性；错误展示由 `tsetattr(...)` 的 C 壳负责。
//! [定位]: 被 `st_attr.zig` 复用，并承载颜色解析单元测试。

const std = @import("std");

pub const ZigColorParse = extern struct {
    idx: i32,
    input_npar: c_int,
    next_npar: c_int,
    kind: c_int,
    r: c_uint,
    g: c_uint,
    b: c_uint,
    value: c_int,
};

pub const color_ok = 0;
pub const color_bad_count = 1;
pub const color_bad_rgb = 2;
pub const color_bad_index = 3;
pub const color_unknown = 4;

pub fn parseColor(attr: []const c_int, npar: c_int) ZigColorParse {
    return (ColorParams{ .args = attr }).parseAt(npar);
}

const ColorParams = struct {
    args: []const c_int,

    fn parseAt(self: ColorParams, npar: c_int) ZigColorParse {
        var result = ColorParse.init(npar);
        const current: usize = @intCast(npar);

        if (current + 1 >= self.args.len) {
            result.setUnknown(if (current < self.args.len) self.args[current] else 0);
            return result.value;
        }

        return switch (self.args[current + 1]) {
            2 => self.parseTrueColor(&result, current, npar),
            5 => self.parseIndexed(&result, current, npar),
            else => blk: {
                result.setUnknown(self.args[current]);
                break :blk result.value;
            },
        };
    }

    fn parseTrueColor(self: ColorParams, result: *ColorParse, current: usize, npar: c_int) ZigColorParse {
        if (current + 4 >= self.args.len) {
            result.setKind(color_bad_count);
            return result.value;
        }

        result.setRgb(@intCast(self.args[current + 2]), @intCast(self.args[current + 3]), @intCast(self.args[current + 4]), npar + 4);
        if (!between(result.value.r, 0, 255) or !between(result.value.g, 0, 255) or !between(result.value.b, 0, 255)) {
            result.setKind(color_bad_rgb);
            return result.value;
        }

        result.value.idx = trueColor(result.value.r, result.value.g, result.value.b);
        return result.value;
    }

    fn parseIndexed(self: ColorParams, result: *ColorParse, current: usize, npar: c_int) ZigColorParse {
        if (current + 2 >= self.args.len) {
            result.setKind(color_bad_count);
            return result.value;
        }

        result.value.next_npar = npar + 2;
        result.value.value = self.args[@intCast(result.value.next_npar)];
        if (!between(@intCast(result.value.value), 0, 255)) {
            result.setKind(color_bad_index);
            return result.value;
        }

        result.value.idx = result.value.value;
        return result.value;
    }
};

const ColorParse = struct {
    value: ZigColorParse,

    fn init(npar: c_int) ColorParse {
        return .{ .value = .{
            .idx = -1,
            .input_npar = npar,
            .next_npar = npar,
            .kind = color_ok,
            .r = 0,
            .g = 0,
            .b = 0,
            .value = 0,
        } };
    }

    fn setKind(self: *ColorParse, kind: c_int) void {
        self.value.kind = kind;
    }

    fn setUnknown(self: *ColorParse, value: c_int) void {
        self.value.kind = color_unknown;
        self.value.value = value;
    }

    fn setRgb(self: *ColorParse, r: c_uint, g: c_uint, b: c_uint, next_npar: c_int) void {
        self.value.r = r;
        self.value.g = g;
        self.value.b = b;
        self.value.next_npar = next_npar;
    }
};

fn trueColor(r: c_uint, g: c_uint, b: c_uint) i32 {
    return @bitCast(@as(u32, (1 << 24) | (r << 16) | (g << 8) | b));
}

fn between(value: c_uint, lower: c_uint, upper: c_uint) bool {
    return lower <= value and value <= upper;
}

test "tdefcolor parses rgb color" {
    const attr = [_]c_int{ 38, 2, 1, 2, 3 };
    const parsed = parseColor(&attr, 0);
    try std.testing.expectEqual(@as(c_int, color_ok), parsed.kind);
    try std.testing.expectEqual(@as(c_int, 0), parsed.input_npar);
    try std.testing.expectEqual(@as(c_int, 4), parsed.next_npar);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x01010203))), parsed.idx);
}

test "tdefcolor parses indexed color" {
    const attr = [_]c_int{ 38, 5, 123 };
    const parsed = parseColor(&attr, 0);
    try std.testing.expectEqual(@as(c_int, color_ok), parsed.kind);
    try std.testing.expectEqual(@as(c_int, 2), parsed.next_npar);
    try std.testing.expectEqual(@as(i32, 123), parsed.idx);
}

test "tdefcolor reports bad count" {
    const attr = [_]c_int{ 38, 2, 1 };
    const parsed = parseColor(&attr, 0);
    try std.testing.expectEqual(@as(c_int, color_bad_count), parsed.kind);
    try std.testing.expectEqual(@as(i32, -1), parsed.idx);
}

test "tdefcolor reports bad rgb" {
    const attr = [_]c_int{ 38, 2, 300, 0, 0 };
    const parsed = parseColor(&attr, 0);
    try std.testing.expectEqual(@as(c_int, color_bad_rgb), parsed.kind);
    try std.testing.expectEqual(@as(c_uint, 300), parsed.r);
}

test "tdefcolor reports bad index" {
    const attr = [_]c_int{ 38, 5, 256 };
    const parsed = parseColor(&attr, 0);
    try std.testing.expectEqual(@as(c_int, color_bad_index), parsed.kind);
    try std.testing.expectEqual(@as(c_int, 256), parsed.value);
}

test "tdefcolor reports unknown mode" {
    const attr = [_]c_int{ 38, 3 };
    const parsed = parseColor(&attr, 0);
    try std.testing.expectEqual(@as(c_int, color_unknown), parsed.kind);
    try std.testing.expectEqual(@as(c_int, 38), parsed.value);
}
