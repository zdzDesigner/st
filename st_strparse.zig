//! st_strparse.zig 负责 OSC/DCS 等字符串序列参数边界解析。
//! [输入]: `strescseq.buf` 和长度，由 C 侧 STR 收集逻辑维护。
//! [输出]: `ZigStrParse`，包含参数数量和每个参数结束位置。
//! [副作用边界]: 不分配、不解码 base64、不设置 title/selection；这些仍在 `strhandle(...)` 的 C 壳中执行。
//! [定位]: 替代 C 侧字符串参数扫描，保留 C 对字符串生命周期的所有权。

const std = @import("std");

const str_arg_siz = 16;

pub const ZigStrParse = extern struct {
    narg: c_int,
    ends: [str_arg_siz]usize,
};

export fn st_strparse(buf: [*]const u8, len: usize) ZigStrParse {
    var result: ZigStrParse = .{
        .narg = 0,
        .ends = std.mem.zeroes([str_arg_siz]usize),
    };

    const input = buf[0..len];
    if (input.len == 0 or input[0] == 0) return result;

    var start: usize = 0;
    while (result.narg < str_arg_siz) {
        var i = start;
        while (i < input.len and input[i] != ';' and input[i] != 0) : (i += 1) {}
        result.ends[@intCast(result.narg)] = i;
        result.narg += 1;
        if (i >= input.len or input[i] == 0) return result;
        start = i + 1;
    }

    return result;
}

test "strparse splits semicolon separated args" {
    const parsed = st_strparse("52;c;Zm9v", 9);
    try std.testing.expectEqual(@as(c_int, 3), parsed.narg);
    try std.testing.expectEqual(@as(usize, 2), parsed.ends[0]);
    try std.testing.expectEqual(@as(usize, 4), parsed.ends[1]);
    try std.testing.expectEqual(@as(usize, 9), parsed.ends[2]);
}

test "strparse returns zero args on empty input" {
    const parsed = st_strparse("", 0);
    try std.testing.expectEqual(@as(c_int, 0), parsed.narg);
}

test "strparse keeps empty segments" {
    const parsed = st_strparse("a;;b", 4);
    try std.testing.expectEqual(@as(c_int, 3), parsed.narg);
    try std.testing.expectEqual(@as(usize, 1), parsed.ends[0]);
    try std.testing.expectEqual(@as(usize, 2), parsed.ends[1]);
    try std.testing.expectEqual(@as(usize, 4), parsed.ends[2]);
}

test "strparse stops at nul terminator" {
    const parsed = st_strparse("ab\x00cd", 5);
    try std.testing.expectEqual(@as(c_int, 1), parsed.narg);
    try std.testing.expectEqual(@as(usize, 2), parsed.ends[0]);
}

test "strparse caps args at fixed limit" {
    const parsed = st_strparse("0;1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16", 38);
    try std.testing.expectEqual(@as(c_int, 16), parsed.narg);
}
