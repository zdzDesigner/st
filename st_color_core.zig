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
    var result: ZigColorParse = .{
        .idx = -1,
        .input_npar = npar,
        .next_npar = npar,
        .kind = color_ok,
        .r = 0,
        .g = 0,
        .b = 0,
        .value = 0,
    };

    const current: usize = @intCast(npar);
    if (current + 1 >= attr.len) {
        result.kind = color_unknown;
        if (current < attr.len) result.value = attr[current];
        return result;
    }

    switch (attr[current + 1]) {
        2 => {
            if (current + 4 >= attr.len) {
                result.kind = color_bad_count;
                return result;
            }
            result.r = @intCast(attr[current + 2]);
            result.g = @intCast(attr[current + 3]);
            result.b = @intCast(attr[current + 4]);
            result.next_npar = npar + 4;
            if (!between(result.r, 0, 255) or !between(result.g, 0, 255) or !between(result.b, 0, 255)) {
                result.kind = color_bad_rgb;
                return result;
            }
            result.idx = trueColor(result.r, result.g, result.b);
            return result;
        },
        5 => {
            if (current + 2 >= attr.len) {
                result.kind = color_bad_count;
                return result;
            }
            result.next_npar = npar + 2;
            result.value = attr[@intCast(result.next_npar)];
            if (!between(@intCast(result.value), 0, 255)) {
                result.kind = color_bad_index;
                return result;
            }
            result.idx = result.value;
            return result;
        },
        else => {
            result.kind = color_unknown;
            result.value = attr[current];
            return result;
        },
    }
}

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
