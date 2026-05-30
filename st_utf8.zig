const std = @import("std");

const utf_invalid: u32 = 0xFFFD;
const utf_siz: usize = 4;

const DecodeResult = extern struct {
    rune: u32,
    len: usize,
};

export fn st_utf8decode(src: [*]const u8, clen: usize) DecodeResult {
    var result = DecodeResult{
        .rune = utf_invalid,
        .len = 0,
    };

    if (clen == 0) return result;

    const first = src[0];
    const seq_len = std.unicode.utf8ByteSequenceLength(first) catch {
        result.len = 1;
        return result;
    };

    if (seq_len < 1 or seq_len > utf_siz) {
        result.len = 1;
        return result;
    }

    var rune: u32 = first & firstMask(seq_len);
    var j: usize = 1;
    var i: usize = 1;
    while (i < clen and j < seq_len) : ({
        i += 1;
        j += 1;
    }) {
        const cont = src[i];
        if ((cont & 0b1100_0000) != 0b1000_0000) {
            result.len = j;
            return result;
        }
        rune = (rune << 6) | @as(u32, cont & 0b0011_1111);
    }

    if (j < seq_len) return result;

    result.rune = validateRune(rune, seq_len);
    result.len = seq_len;
    return result;
}

export fn st_utf8encode(rune: u32, out: [*]u8) usize {
    const valid_rune = validateRune(rune, 0);
    var buf: [utf_siz]u8 = undefined;
    const len = std.unicode.utf8Encode(valid_rune, &buf) catch return 0;
    @memcpy(out[0..len], buf[0..len]);
    return len;
}

fn firstMask(seq_len: usize) u8 {
    return switch (seq_len) {
        1 => 0b0111_1111,
        2 => 0b0001_1111,
        3 => 0b0000_1111,
        4 => 0b0000_0111,
        else => 0,
    };
}

fn validateRune(rune: u32, seq_len: usize) u21 {
    var value = rune;
    if (!between(value, utfMin(seq_len), utfMax(seq_len)) or between(value, 0xD800, 0xDFFF)) {
        value = utf_invalid;
    }
    return @intCast(value);
}

fn utfMin(seq_len: usize) u32 {
    return switch (seq_len) {
        0, 1 => 0,
        2 => 0x80,
        3 => 0x800,
        4 => 0x10000,
        else => 0,
    };
}

fn utfMax(seq_len: usize) u32 {
    return switch (seq_len) {
        0 => 0x10FFFF,
        1 => 0x7F,
        2 => 0x7FF,
        3 => 0xFFFF,
        4 => 0x10FFFF,
        else => 0,
    };
}

fn between(value: u32, lower: u32, upper: u32) bool {
    return lower <= value and value <= upper;
}

test "utf8 decode ascii" {
    const result = st_utf8decode("A", 1);
    try std.testing.expectEqual(@as(u32, 'A'), result.rune);
    try std.testing.expectEqual(@as(usize, 1), result.len);
}

test "utf8 decode euro sign" {
    const result = st_utf8decode("€", 3);
    try std.testing.expectEqual(@as(u32, 0x20AC), result.rune);
    try std.testing.expectEqual(@as(usize, 3), result.len);
}

test "utf8 decode invalid continuation returns consumed count" {
    const bytes = [_]u8{ 0xE2, 'A', 0x82 };
    const result = st_utf8decode(&bytes, bytes.len);
    try std.testing.expectEqual(@as(u32, utf_invalid), result.rune);
    try std.testing.expectEqual(@as(usize, 1), result.len);
}

test "utf8 decode truncated sequence returns zero" {
    const bytes = [_]u8{0xE2};
    const result = st_utf8decode(&bytes, bytes.len);
    try std.testing.expectEqual(@as(u32, utf_invalid), result.rune);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "utf8 encode replacement for surrogate" {
    var buf: [utf_siz]u8 = undefined;
    const len = st_utf8encode(0xD800, &buf);
    try std.testing.expectEqual(@as(usize, 3), len);
    try std.testing.expectEqualSlices(u8, &std.unicode.replacement_character_utf8, buf[0..len]);
}
