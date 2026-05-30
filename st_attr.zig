const std = @import("std");
const color = @import("st_color_core.zig");

const ZigAttrState = extern struct {
    mode: c_ushort,
    fg: u32,
    bg: u32,
};

const ZigAttrUpdate = extern struct {
    state: ZigAttrState,
    error_kind: c_int,
    error_value: c_int,
    error_index: c_int,
    color_error: color.ZigColorParse,
};

const attr_bold = 1 << 0;
const attr_faint = 1 << 1;
const attr_italic = 1 << 2;
const attr_underline = 1 << 3;
const attr_blink = 1 << 4;
const attr_reverse = 1 << 5;
const attr_invisible = 1 << 6;
const attr_struck = 1 << 7;

const attr_error_none = 0;
const attr_error_unknown = 1;

export fn st_tsetattr(current: ZigAttrState, defaultfg: u32, defaultbg: u32, attr: [*]const c_int, len: c_int) ZigAttrUpdate {
    var result: ZigAttrUpdate = .{
        .state = current,
        .error_kind = attr_error_none,
        .error_value = 0,
        .error_index = -1,
        .color_error = .{
            .idx = -1,
            .input_npar = 0,
            .next_npar = 0,
            .kind = 0,
            .r = 0,
            .g = 0,
            .b = 0,
            .value = 0,
        },
    };

    const args = attr[0..@intCast(len)];
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        switch (args[i]) {
            0 => {
                result.state.mode &= ~@as(c_ushort, attr_bold | attr_faint | attr_italic | attr_underline | attr_blink | attr_reverse | attr_invisible | attr_struck);
                result.state.fg = defaultfg;
                result.state.bg = defaultbg;
            },
            1 => result.state.mode |= attr_bold,
            2 => result.state.mode |= attr_faint,
            3 => result.state.mode |= attr_italic,
            4 => result.state.mode |= attr_underline,
            5, 6 => result.state.mode |= attr_blink,
            7 => result.state.mode |= attr_reverse,
            8 => result.state.mode |= attr_invisible,
            9 => result.state.mode |= attr_struck,
            22 => result.state.mode &= ~@as(c_ushort, attr_bold | attr_faint),
            23 => result.state.mode &= ~@as(c_ushort, attr_italic),
            24 => result.state.mode &= ~@as(c_ushort, attr_underline),
            25 => result.state.mode &= ~@as(c_ushort, attr_blink),
            27 => result.state.mode &= ~@as(c_ushort, attr_reverse),
            28 => result.state.mode &= ~@as(c_ushort, attr_invisible),
            29 => result.state.mode &= ~@as(c_ushort, attr_struck),
            38 => {
                const npar: c_int = @intCast(i);
                const parsed = color.parseColor(args, npar);
                result.color_error = parsed;
                i = @intCast(parsed.next_npar);
                if (parsed.idx >= 0) result.state.fg = @bitCast(parsed.idx);
            },
            39 => result.state.fg = defaultfg,
            48 => {
                const npar: c_int = @intCast(i);
                const parsed = color.parseColor(args, npar);
                result.color_error = parsed;
                i = @intCast(parsed.next_npar);
                if (parsed.idx >= 0) result.state.bg = @bitCast(parsed.idx);
            },
            49 => result.state.bg = defaultbg,
            else => {
                if (between(args[i], 30, 37)) {
                    result.state.fg = @intCast(args[i] - 30);
                } else if (between(args[i], 40, 47)) {
                    result.state.bg = @intCast(args[i] - 40);
                } else if (between(args[i], 90, 97)) {
                    result.state.fg = @intCast(args[i] - 90 + 8);
                } else if (between(args[i], 100, 107)) {
                    result.state.bg = @intCast(args[i] - 100 + 8);
                } else {
                    result.error_kind = attr_error_unknown;
                    result.error_value = args[i];
                    result.error_index = @intCast(i);
                }
            },
        }
    }

    return result;
}

fn between(value: c_int, lower: c_int, upper: c_int) bool {
    return lower <= value and value <= upper;
}

test "tsetattr sets bold and underline" {
    const update = st_tsetattr(.{ .mode = 0, .fg = 7, .bg = 0 }, 7, 0, &[_]c_int{ 1, 4 }, 2);
    try std.testing.expectEqual(@as(c_ushort, attr_bold | attr_underline), update.state.mode);
    try std.testing.expectEqual(@as(c_int, attr_error_none), update.error_kind);
}

test "tsetattr resets colors and modes" {
    const update = st_tsetattr(.{ .mode = attr_bold | attr_blink, .fg = 3, .bg = 4 }, 7, 0, &[_]c_int{0}, 1);
    try std.testing.expectEqual(@as(c_ushort, 0), update.state.mode);
    try std.testing.expectEqual(@as(u32, 7), update.state.fg);
    try std.testing.expectEqual(@as(u32, 0), update.state.bg);
}

test "tsetattr applies ansi bright colors" {
    const update = st_tsetattr(.{ .mode = 0, .fg = 7, .bg = 0 }, 7, 0, &[_]c_int{ 91, 104 }, 2);
    try std.testing.expectEqual(@as(u32, 9), update.state.fg);
    try std.testing.expectEqual(@as(u32, 12), update.state.bg);
}

test "tsetattr accepts indexed fg color" {
    const update = st_tsetattr(.{ .mode = 0, .fg = 7, .bg = 0 }, 7, 0, &[_]c_int{ 38, 5, 123 }, 3);
    try std.testing.expectEqual(@as(u32, 123), update.state.fg);
}

test "tsetattr records unknown attribute" {
    const update = st_tsetattr(.{ .mode = 0, .fg = 7, .bg = 0 }, 7, 0, &[_]c_int{999}, 1);
    try std.testing.expectEqual(@as(c_int, attr_error_unknown), update.error_kind);
    try std.testing.expectEqual(@as(c_int, 999), update.error_value);
    try std.testing.expectEqual(@as(c_int, 0), update.error_index);
}
