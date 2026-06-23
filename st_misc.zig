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

pub const misc_none = 0;
pub const misc_media_dump = 1;
pub const misc_media_dump_line = 2;
pub const misc_media_dump_sel = 3;
pub const misc_media_print_off = 4;
pub const misc_media_print_on = 5;
pub const misc_repeat_last = 6;
pub const misc_set_cursor_style = 7;
pub const misc_unknown = 8;

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

export fn st_tdectest(c: c_char) c_int {
    return if (c == '8') 1 else 0;
}

export fn st_ttywritecount(n: usize, limit: usize) usize {
    return if (n < limit) n else limit;
}

export fn st_ttywritechunk(input: [*]const u8, len: usize) usize {
    return (TtyWrite{ .input = input[0..len] }).chunk();
}

export fn st_tprinterwrite(iofd: c_int) c_int {
    return if (iofd != -1) 1 else 0;
}

export fn st_sttyfits(len: usize, available: usize) c_int {
    return if (len < available) 1 else 0;
}

export fn st_ttyreadpending(buflen: c_int) c_int {
    return if (buflen > 0) 1 else 0;
}

test "dectest only accepts alignment selector" {
    try std.testing.expectEqual(@as(c_int, 1), st_tdectest('8'));
    try std.testing.expectEqual(@as(c_int, 0), st_tdectest('7'));
}

test "tty write count clamps to limit" {
    try std.testing.expectEqual(@as(usize, 12), st_ttywritecount(12, 256));
    try std.testing.expectEqual(@as(usize, 256), st_ttywritecount(300, 256));
}

test "tty write chunk stops at carriage return" {
    try std.testing.expectEqual(@as(usize, 3), st_ttywritechunk("abc\rdef", 7));
    try std.testing.expectEqual(@as(usize, 3), st_ttywritechunk("abc", 3));
}

test "printer write requires open fd" {
    try std.testing.expectEqual(@as(c_int, 0), st_tprinterwrite(-1));
    try std.testing.expectEqual(@as(c_int, 1), st_tprinterwrite(3));
}

test "stty length must leave room for terminator" {
    try std.testing.expectEqual(@as(c_int, 1), st_sttyfits(3, 4));
    try std.testing.expectEqual(@as(c_int, 0), st_sttyfits(4, 4));
}

test "tty read pending follows buffered byte count" {
    try std.testing.expectEqual(@as(c_int, 0), st_ttyreadpending(0));
    try std.testing.expectEqual(@as(c_int, 1), st_ttyreadpending(2));
}
