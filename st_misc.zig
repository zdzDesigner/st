//! st_misc.zig 负责 tty/printer 辅助规划和 DEC 测试 selector。
//! [输入]: tty 写入缓冲、长度限制、printer fd 和 DEC 测试字符。
//! [输出]: 写入 chunk/count、printer 是否可写、stty 长度判断或 DEC 测试判断。
//! [副作用边界]: 不调用 `tdump(...)`、`tputc(...)`、`xsetcursor(...)`、`write(...)`；C 侧执行真实动作。
//! [定位]: 支撑 C executor 的杂项 IO 边界；CSI misc 顶层分类已收敛到 `st_csi.zig`。

const std = @import("std");

pub const ZigMiscPlan = extern struct {
    kind: c_int,
    value: c_int,
    extra: c_int,
};

pub const ZigIoEffect = extern struct {
    kind: c_int,
    offset: usize,
    len: usize,
};

pub const ZigIoEffectList = extern struct {
    count: c_int,
    consumed: usize,
    effects: [32]ZigIoEffect,
};

pub const misc_none = 0;
pub const misc_media_dump = 1;
pub const misc_media_dump_line = 2;
pub const misc_media_dump_sel = 3;
pub const misc_media_print_off = 4;
pub const misc_media_print_on = 5;
pub const misc_repeat_last = 6;
pub const misc_set_cursor_style = 7;
pub const misc_unknown = 8;
pub const io_effect_raw = 1;
pub const io_effect_crlf = 2;

const TtyWrite = struct {
    input: []const u8,

    fn chunk(self: TtyWrite) usize {
        var index: usize = 0;
        while (index < self.input.len and self.input[index] != '\r') {
            index += 1;
        }
        return index;
    }
};

export fn st_ttywriteeffects(input: [*]const u8, len: usize, crlf: c_int) ZigIoEffectList {
    var list = ZigIoEffectList{ .count = 0, .consumed = 0, .effects = std.mem.zeroes([32]ZigIoEffect) };
    const bytes = input[0..len];
    if (len == 0) return list;
    if (crlf == 0) {
        list.effects[0] = .{ .kind = io_effect_raw, .offset = 0, .len = len };
        list.count = 1;
        list.consumed = len;
        return list;
    }

    var offset: usize = 0;
    while (offset < len and @as(usize, @intCast(list.count)) < list.effects.len) {
        if (bytes[offset] == '\r') {
            list.effects[@intCast(list.count)] = .{ .kind = io_effect_crlf, .offset = offset, .len = 2 };
            list.count += 1;
            offset += 1;
        } else {
            const start = offset;
            while (offset < len and bytes[offset] != '\r') : (offset += 1) {}
            list.effects[@intCast(list.count)] = .{ .kind = io_effect_raw, .offset = start, .len = offset - start };
            list.count += 1;
        }
    }
    list.consumed = offset;
    return list;
}

test "tty write helper stops at carriage return" {
    try std.testing.expectEqual(@as(usize, 3), (TtyWrite{ .input = "abc\rdef" }).chunk());
    try std.testing.expectEqual(@as(usize, 3), (TtyWrite{ .input = "abc" }).chunk());
}

test "tty write effects split carriage returns" {
    const input = "a\rb";
    const effects = st_ttywriteeffects(input, input.len, 1);

    try std.testing.expectEqual(@as(c_int, 3), effects.count);
    try std.testing.expectEqual(@as(usize, input.len), effects.consumed);
    try std.testing.expectEqual(@as(c_int, io_effect_raw), effects.effects[0].kind);
    try std.testing.expectEqual(@as(usize, 0), effects.effects[0].offset);
    try std.testing.expectEqual(@as(usize, 1), effects.effects[0].len);
    try std.testing.expectEqual(@as(c_int, io_effect_crlf), effects.effects[1].kind);
    try std.testing.expectEqual(@as(c_int, io_effect_raw), effects.effects[2].kind);
    try std.testing.expectEqual(@as(usize, 2), effects.effects[2].offset);
}

test "tty write effects keep raw chunk without crlf mode" {
    const input = "a\rb";
    const effects = st_ttywriteeffects(input, input.len, 0);

    try std.testing.expectEqual(@as(c_int, 1), effects.count);
    try std.testing.expectEqual(@as(usize, input.len), effects.consumed);
    try std.testing.expectEqual(@as(c_int, io_effect_raw), effects.effects[0].kind);
}
