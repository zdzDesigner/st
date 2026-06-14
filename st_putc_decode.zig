//! st_putc_decode.zig 负责 `tputc(...)` 前段的 rune 分类与 UTF-8 编码。
//! [输入]: 一个 Unicode rune 和当前 UTF-8 mode 标志。
//! [输出]: `ZigPutcDecode`，包含是否是控制字符、显示宽度、编码长度和最多 4 字节输出。
//! [副作用边界]: 不打印、不写 tty、不修改 `term.lastc`；C 侧继续负责控制码执行和输出路径。
//! [定位]: 让 `tputc(...)` 的解码/宽度判断从 C 迁为可测试 Zig 逻辑。

const std = @import("std");

pub const ZigPutcDecode = extern struct {
    control: c_int,
    width: c_int,
    len: c_int,
    bytes: [4]u8,
};

export fn st_putcdecode(rune: u32, utf8_mode: c_int) ZigPutcDecode {
    var result: ZigPutcDecode = .{
        .control = if (isControl(rune)) 1 else 0,
        .width = 1,
        .len = 1,
        .bytes = std.mem.zeroes([4]u8),
    };

    if (rune < 127 or utf8_mode == 0) {
        result.bytes[0] = @truncate(rune);
        return result;
    }

    result.len = @intCast(encodeRune(rune, &result.bytes));
    if (result.control == 0) {
        result.width = runeWidth(rune);
    }
    return result;
}

fn isControl(rune: u32) bool {
    return rune <= 0x1f or rune == 0x7f or (0x80 <= rune and rune <= 0x9f);
}

fn encodeRune(rune: u32, out: *[4]u8) usize {
    const valid = validateRune(rune);
    return std.unicode.utf8Encode(valid, out) catch 0;
}

fn validateRune(rune: u32) u21 {
    var value = rune;
    if (value > 0x10FFFF or (0xD800 <= value and value <= 0xDFFF)) {
        value = 0xFFFD;
    }
    return @intCast(value);
}

fn runeWidth(rune: u32) c_int {
    if (std.unicode.utf8ValidCodepoint(@intCast(validateRune(rune)))) {
        const width = std.unicode.utf8CodepointSequenceLength(@intCast(validateRune(rune))) catch 1;
        _ = width;
    }

    return if (isWide(rune)) 2 else 1;
}

fn isWide(rune: u32) bool {
    return switch (rune) {
        0x1100...0x115F, 0x2329...0x232A, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD => true,
        else => false,
    };
}

test "putc decode ascii in non utf8 mode" {
    const decoded = st_putcdecode('A', 0);
    try std.testing.expectEqual(@as(c_int, 0), decoded.control);
    try std.testing.expectEqual(@as(c_int, 1), decoded.len);
    try std.testing.expectEqual(@as(c_int, 1), decoded.width);
    try std.testing.expectEqual(@as(u8, 'A'), decoded.bytes[0]);
}

test "putc decode utf8 euro sign" {
    const decoded = st_putcdecode(0x20AC, 1);
    try std.testing.expectEqual(@as(c_int, 0), decoded.control);
    try std.testing.expectEqual(@as(c_int, 3), decoded.len);
    try std.testing.expectEqual(@as(c_int, 1), decoded.width);
}

test "putc decode control rune stays width one" {
    const decoded = st_putcdecode(0x1b, 1);
    try std.testing.expectEqual(@as(c_int, 1), decoded.control);
    try std.testing.expectEqual(@as(c_int, 1), decoded.width);
}

test "putc decode wide rune reports width two" {
    const decoded = st_putcdecode(0x4E2D, 1);
    try std.testing.expectEqual(@as(c_int, 2), decoded.width);
}

test "putc decode surrogate encodes replacement" {
    const decoded = st_putcdecode(0xD800, 1);
    try std.testing.expectEqual(@as(c_int, 3), decoded.len);
}
