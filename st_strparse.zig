//! st_strparse.zig 负责 OSC/DCS 等字符串序列参数边界解析。
//! [输入]: `strescseq.buf` 和长度，由 C 侧 STR 收集逻辑维护。
//! [输出]: `ZigStrParse`，包含参数数量和每个参数结束位置。
//! [副作用边界]: 不分配、不解码 base64、不设置 title/selection；这些仍在 `strhandle(...)` 的 C 壳中执行。
//! [定位]: 替代 C 侧字符串参数扫描，保留 C 对字符串生命周期的所有权。

const std = @import("std");

const str_arg_siz = 16;

pub const ZigStrParse = extern struct {
    narg: c_int,
    starts: [str_arg_siz]usize,
    ends: [str_arg_siz]usize,
    nul_terms: [str_arg_siz]c_int,
};

const StringParser = struct {
    input: []const u8,

    fn parse(self: StringParser) ZigStrParse {
        var result: ZigStrParse = .{
            .narg = 0,
            .starts = std.mem.zeroes([str_arg_siz]usize),
            .ends = std.mem.zeroes([str_arg_siz]usize),
            .nul_terms = std.mem.zeroes([str_arg_siz]c_int),
        };

        if (self.input.len == 0 or self.input[0] == 0) return result;

        var start: usize = 0;
        while (result.narg < str_arg_siz) {
            var i = start;
            while (i < self.input.len and self.input[i] != ';' and self.input[i] != 0) : (i += 1) {}
            result.starts[@intCast(result.narg)] = start;
            result.ends[@intCast(result.narg)] = i;
            result.nul_terms[@intCast(result.narg)] = if (i < self.input.len and self.input[i] == ';') 1 else 0;
            result.narg += 1;
            if (i >= self.input.len or self.input[i] == 0) return result;
            start = i + 1;
        }

        return result;
    }
};

export fn st_strparse(buf: [*]const u8, len: usize) ZigStrParse {
    return (StringParser{ .input = buf[0..len] }).parse();
}

test "strparse splits semicolon separated args" {
    const parsed = st_strparse("52;c;Zm9v", 9);
    try std.testing.expectEqual(@as(c_int, 3), parsed.narg);
    try std.testing.expectEqual(@as(usize, 0), parsed.starts[0]);
    try std.testing.expectEqual(@as(usize, 2), parsed.ends[0]);
    try std.testing.expectEqual(@as(c_int, 1), parsed.nul_terms[0]);
    try std.testing.expectEqual(@as(usize, 3), parsed.starts[1]);
    try std.testing.expectEqual(@as(usize, 4), parsed.ends[1]);
    try std.testing.expectEqual(@as(c_int, 1), parsed.nul_terms[1]);
    try std.testing.expectEqual(@as(usize, 5), parsed.starts[2]);
    try std.testing.expectEqual(@as(usize, 9), parsed.ends[2]);
    try std.testing.expectEqual(@as(c_int, 0), parsed.nul_terms[2]);
}

test "strparse returns zero args on empty input" {
    const parsed = st_strparse("", 0);
    try std.testing.expectEqual(@as(c_int, 0), parsed.narg);
}

test "strparse keeps empty segments" {
    const parsed = st_strparse("a;;b", 4);
    try std.testing.expectEqual(@as(c_int, 3), parsed.narg);
    try std.testing.expectEqual(@as(usize, 0), parsed.starts[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.ends[0]);
    try std.testing.expectEqual(@as(usize, 2), parsed.starts[1]);
    try std.testing.expectEqual(@as(usize, 2), parsed.ends[1]);
    try std.testing.expectEqual(@as(usize, 3), parsed.starts[2]);
    try std.testing.expectEqual(@as(usize, 4), parsed.ends[2]);
}

test "strparse records leading empty segment" {
    const parsed = st_strparse(";b", 2);

    try std.testing.expectEqual(@as(c_int, 2), parsed.narg);
    try std.testing.expectEqual(@as(usize, 0), parsed.starts[0]);
    try std.testing.expectEqual(@as(usize, 0), parsed.ends[0]);
    try std.testing.expectEqual(@as(c_int, 1), parsed.nul_terms[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.starts[1]);
    try std.testing.expectEqual(@as(usize, 2), parsed.ends[1]);
    try std.testing.expectEqual(@as(c_int, 0), parsed.nul_terms[1]);
}

test "strparse stops at nul terminator" {
    const parsed = st_strparse("ab\x00cd", 5);
    try std.testing.expectEqual(@as(c_int, 1), parsed.narg);
    try std.testing.expectEqual(@as(usize, 2), parsed.ends[0]);
    try std.testing.expectEqual(@as(c_int, 0), parsed.nul_terms[0]);
}

test "strparse records trailing empty segment" {
    const parsed = st_strparse("a;", 2);

    try std.testing.expectEqual(@as(c_int, 2), parsed.narg);
    try std.testing.expectEqual(@as(usize, 0), parsed.starts[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.ends[0]);
    try std.testing.expectEqual(@as(c_int, 1), parsed.nul_terms[0]);
    try std.testing.expectEqual(@as(usize, 2), parsed.starts[1]);
    try std.testing.expectEqual(@as(usize, 2), parsed.ends[1]);
    try std.testing.expectEqual(@as(c_int, 0), parsed.nul_terms[1]);
}

test "strparse caps args at fixed limit" {
    const parsed = st_strparse("0;1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16", 38);
    try std.testing.expectEqual(@as(c_int, 16), parsed.narg);
    try std.testing.expectEqual(@as(usize, 35), parsed.starts[15]);
    try std.testing.expectEqual(@as(usize, 37), parsed.ends[15]);
}
