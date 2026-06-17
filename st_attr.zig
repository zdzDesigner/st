//! st_attr.zig 负责 SGR 属性更新逻辑，是 `tsetattr(...)` 的 Zig 迁移主体。
//! [输入]: 当前 glyph 属性、默认前景/背景色，以及 CSI `m` 参数数组。
//! [输出]: 新的属性状态、普通属性错误和颜色解析错误。
//! [副作用边界]: 只计算 `term.c.attr` 应变成什么；错误打印、`csidump()` 和 C 全局状态写回仍在 C 侧。
//! [定位]: 把复杂 SGR 分支从 `st.c` 收敛为一个可测试的属性状态转换器。

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

const AttrDefaults = struct {
    fg: u32,
    bg: u32,
};

const AttrUpdate = struct {
    result: ZigAttrUpdate,
    defaults: AttrDefaults,

    fn init(current: ZigAttrState, defaults: AttrDefaults) AttrUpdate {
        return .{
            .result = .{
                .state = current,
                .error_kind = attr_error_none,
                .error_value = 0,
                .error_index = -1,
                .color_error = emptyColorError(),
            },
            .defaults = defaults,
        };
    }

    fn reset(self: *AttrUpdate) void {
        self.result.state.mode &= ~@as(c_ushort, attr_bold | attr_faint | attr_italic | attr_underline | attr_blink | attr_reverse | attr_invisible | attr_struck);
        self.result.state.fg = self.defaults.fg;
        self.result.state.bg = self.defaults.bg;
    }

    fn setMode(self: *AttrUpdate, mask: c_ushort) void {
        self.result.state.mode |= mask;
    }

    fn clearMode(self: *AttrUpdate, mask: c_ushort) void {
        self.result.state.mode &= ~mask;
    }

    fn setUnknown(self: *AttrUpdate, value: c_int, index: usize) void {
        self.result.error_kind = attr_error_unknown;
        self.result.error_value = value;
        self.result.error_index = @intCast(index);
    }

    fn setForeground(self: *AttrUpdate, value: u32) void {
        self.result.state.fg = value;
    }

    fn setBackground(self: *AttrUpdate, value: u32) void {
        self.result.state.bg = value;
    }

    fn parseForeground(self: *AttrUpdate, args: []const c_int, index: usize) usize {
        const parsed = color.parseColor(args, @intCast(index));
        self.result.color_error = parsed;
        if (parsed.idx >= 0) self.setForeground(@bitCast(parsed.idx));
        return @intCast(parsed.next_npar);
    }

    fn parseBackground(self: *AttrUpdate, args: []const c_int, index: usize) usize {
        const parsed = color.parseColor(args, @intCast(index));
        self.result.color_error = parsed;
        if (parsed.idx >= 0) self.setBackground(@bitCast(parsed.idx));
        return @intCast(parsed.next_npar);
    }
};

const SgrParams = struct {
    args: []const c_int,
    defaults: AttrDefaults,

    fn apply(self: SgrParams, current: ZigAttrState) ZigAttrUpdate {
        var update = AttrUpdate.init(current, self.defaults);

        var index: usize = 0;
        while (index < self.args.len) : (index += 1) {
            index = self.applyOne(&update, index);
        }

        return update.result;
    }

    fn applyOne(self: SgrParams, update: *AttrUpdate, index: usize) usize {
        const value = self.args[index];
        switch (value) {
            0 => update.reset(),
            1 => update.setMode(attr_bold),
            2 => update.setMode(attr_faint),
            3 => update.setMode(attr_italic),
            4 => update.setMode(attr_underline),
            5, 6 => update.setMode(attr_blink),
            7 => update.setMode(attr_reverse),
            8 => update.setMode(attr_invisible),
            9 => update.setMode(attr_struck),
            22 => update.clearMode(attr_bold | attr_faint),
            23 => update.clearMode(attr_italic),
            24 => update.clearMode(attr_underline),
            25 => update.clearMode(attr_blink),
            27 => update.clearMode(attr_reverse),
            28 => update.clearMode(attr_invisible),
            29 => update.clearMode(attr_struck),
            38 => return update.parseForeground(self.args, index),
            39 => update.setForeground(self.defaults.fg),
            48 => return update.parseBackground(self.args, index),
            49 => update.setBackground(self.defaults.bg),
            else => self.applyColorAlias(update, value, index),
        }
        return index;
    }

    fn applyColorAlias(self: SgrParams, update: *AttrUpdate, value: c_int, index: usize) void {
        _ = self;
        if (between(value, 30, 37)) {
            update.setForeground(@intCast(value - 30));
        } else if (between(value, 40, 47)) {
            update.setBackground(@intCast(value - 40));
        } else if (between(value, 90, 97)) {
            update.setForeground(@intCast(value - 90 + 8));
        } else if (between(value, 100, 107)) {
            update.setBackground(@intCast(value - 100 + 8));
        } else {
            update.setUnknown(value, index);
        }
    }
};

export fn st_tsetattr(current: ZigAttrState, defaultfg: u32, defaultbg: u32, attr: [*]const c_int, len: c_int) ZigAttrUpdate {
    return (SgrParams{
        .args = attr[0..@intCast(len)],
        .defaults = .{ .fg = defaultfg, .bg = defaultbg },
    }).apply(current);
}

fn emptyColorError() color.ZigColorParse {
    return .{
        .idx = -1,
        .input_npar = 0,
        .next_npar = 0,
        .kind = 0,
        .r = 0,
        .g = 0,
        .b = 0,
        .value = 0,
    };
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
