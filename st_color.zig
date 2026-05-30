const std = @import("std");
const core = @import("st_color_core.zig");

pub export fn st_tdefcolor(attr: [*]const c_int, npar: c_int, len: c_int) core.ZigColorParse {
    return core.parseColor(attr[0..@intCast(len)], npar);
}

test "tdefcolor parses rgb color" {
    const attr = [_]c_int{ 38, 2, 1, 2, 3 };
    const parsed = core.parseColor(&attr, 0);
    try std.testing.expectEqual(@as(c_int, core.color_ok), parsed.kind);
    try std.testing.expectEqual(@as(c_int, 0), parsed.input_npar);
    try std.testing.expectEqual(@as(c_int, 4), parsed.next_npar);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x01010203))), parsed.idx);
}

test "tdefcolor parses indexed color" {
    const attr = [_]c_int{ 38, 5, 123 };
    const parsed = core.parseColor(&attr, 0);
    try std.testing.expectEqual(@as(c_int, core.color_ok), parsed.kind);
    try std.testing.expectEqual(@as(c_int, 2), parsed.next_npar);
    try std.testing.expectEqual(@as(i32, 123), parsed.idx);
}

test "tdefcolor reports bad count" {
    const attr = [_]c_int{ 38, 2, 1 };
    const parsed = core.parseColor(&attr, 0);
    try std.testing.expectEqual(@as(c_int, core.color_bad_count), parsed.kind);
    try std.testing.expectEqual(@as(i32, -1), parsed.idx);
}

test "tdefcolor reports bad rgb" {
    const attr = [_]c_int{ 38, 2, 300, 0, 0 };
    const parsed = core.parseColor(&attr, 0);
    try std.testing.expectEqual(@as(c_int, core.color_bad_rgb), parsed.kind);
    try std.testing.expectEqual(@as(c_uint, 300), parsed.r);
}

test "tdefcolor reports bad index" {
    const attr = [_]c_int{ 38, 5, 256 };
    const parsed = core.parseColor(&attr, 0);
    try std.testing.expectEqual(@as(c_int, core.color_bad_index), parsed.kind);
    try std.testing.expectEqual(@as(c_int, 256), parsed.value);
}

test "tdefcolor reports unknown mode" {
    const attr = [_]c_int{ 38, 3 };
    const parsed = core.parseColor(&attr, 0);
    try std.testing.expectEqual(@as(c_int, core.color_unknown), parsed.kind);
    try std.testing.expectEqual(@as(c_int, 38), parsed.value);
}
