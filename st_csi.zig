//! st_csi.zig 负责把 CSI 原始字节解析成 C 可消费的固定布局结构。
//! [输入]: `csiescseq.buf` 和长度，由 C 在 ESC/CSI 收集阶段维护。
//! [输出]: `ZigCsiParse`，包含 private marker、参数数组、参数数量和 mode 字节。
//! [副作用边界]: 只解析字节，不执行任何 CSI 动作；未知序列、光标移动、清屏等仍由 C 侧调度。
//! [定位]: 位于 `csiparse(...)` 边界，用来减少 C 侧字符串解析逻辑。

const std = @import("std");

const csi_arg_siz = 16;

const ZigCsiParse = extern struct {
    priv: c_char,
    arg: [csi_arg_siz]c_int,
    narg: c_int,
    mode: [2]c_char,
};

export fn st_csiparse(buf: [*]const u8, len: usize) ZigCsiParse {
    var result: ZigCsiParse = std.mem.zeroes(ZigCsiParse);
    const input = buf[0..len];
    var i: usize = 0;

    if (i < input.len and input[i] == '?') {
        result.priv = '?';
        i += 1;
    }

    while (i < input.len and result.narg < csi_arg_siz) {
        const parsed = parseArg(input, i);
        result.arg[@intCast(result.narg)] = parsed.value;
        result.narg += 1;
        i = parsed.next;
        if (i >= input.len or input[i] != ';' or result.narg == csi_arg_siz) break;
        i += 1;
    }

    if (i < input.len) {
        result.mode[0] = @intCast(input[i]);
        i += 1;
    }
    if (i < input.len) {
        result.mode[1] = @intCast(input[i]);
    }

    return result;
}

const ParsedArg = struct {
    value: c_int,
    next: usize,
};

fn parseArg(input: []const u8, start: usize) ParsedArg {
    var i = start;
    if (i < input.len and (input[i] == '+' or input[i] == '-')) {
        i += 1;
    }

    const digits_start = i;
    while (i < input.len and std.ascii.isDigit(input[i])) : (i += 1) {}
    if (digits_start == i) {
        return .{ .value = 0, .next = start };
    }

    const token = input[start..i];
    const parsed = std.fmt.parseInt(i64, token, 10) catch return .{ .value = -1, .next = i };
    const value = std.math.cast(c_int, parsed) orelse -1;
    return .{ .value = value, .next = i };
}

test "csi parse regular args" {
    const parsed = st_csiparse("31;1m", 5);
    try std.testing.expectEqual(@as(c_char, 0), parsed.priv);
    try std.testing.expectEqual(@as(c_int, 2), parsed.narg);
    try std.testing.expectEqual(@as(c_int, 31), parsed.arg[0]);
    try std.testing.expectEqual(@as(c_int, 1), parsed.arg[1]);
    try std.testing.expectEqual(@as(c_char, 'm'), parsed.mode[0]);
    try std.testing.expectEqual(@as(c_char, 0), parsed.mode[1]);
}

test "csi parse private mode" {
    const parsed = st_csiparse("?25h", 4);
    try std.testing.expectEqual(@as(c_char, '?'), parsed.priv);
    try std.testing.expectEqual(@as(c_int, 1), parsed.narg);
    try std.testing.expectEqual(@as(c_int, 25), parsed.arg[0]);
    try std.testing.expectEqual(@as(c_char, 'h'), parsed.mode[0]);
}

test "csi parse empty arg before mode" {
    const parsed = st_csiparse(";m", 2);
    try std.testing.expectEqual(@as(c_int, 2), parsed.narg);
    try std.testing.expectEqual(@as(c_int, 0), parsed.arg[0]);
    try std.testing.expectEqual(@as(c_int, 0), parsed.arg[1]);
    try std.testing.expectEqual(@as(c_char, 'm'), parsed.mode[0]);
}

test "csi parse overflow becomes minus one" {
    const parsed = st_csiparse("999999999999999999999m", 22);
    try std.testing.expectEqual(@as(c_int, 1), parsed.narg);
    try std.testing.expectEqual(@as(c_int, -1), parsed.arg[0]);
    try std.testing.expectEqual(@as(c_char, 'm'), parsed.mode[0]);
}
