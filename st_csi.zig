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
    return (CsiParser{ .input = buf[0..len] }).parse();
}

export fn st_csiprivbool(priv: c_char) c_int {
    return if (priv != 0) 1 else 0;
}

const ParsedArg = struct {
    value: c_int,
    next: usize,
};

const CsiParser = struct {
    input: []const u8,

    fn parse(self: CsiParser) ZigCsiParse {
        var result: ZigCsiParse = std.mem.zeroes(ZigCsiParse);
        var index: usize = 0;

        if (index < self.input.len and self.input[index] == '?') {
            result.priv = '?';
            index += 1;
        }

        while (index < self.input.len and result.narg < csi_arg_siz) {
            const parsed = (CsiArgParser{ .input = self.input, .start = index }).parse();
            result.arg[@intCast(result.narg)] = parsed.value;
            result.narg += 1;
            index = parsed.next;
            if (index >= self.input.len or self.input[index] != ';' or result.narg == csi_arg_siz) break;
            index += 1;
        }

        if (index < self.input.len) {
            result.mode[0] = @intCast(self.input[index]);
            index += 1;
        }
        if (index < self.input.len) {
            result.mode[1] = @intCast(self.input[index]);
        }

        return result;
    }
};

const CsiArgParser = struct {
    input: []const u8,
    start: usize,

    fn parse(self: CsiArgParser) ParsedArg {
        var index = self.start;
        if (index < self.input.len and (self.input[index] == '+' or self.input[index] == '-')) {
            index += 1;
        }

        const digits_start = index;
        while (index < self.input.len and std.ascii.isDigit(self.input[index])) : (index += 1) {}
        if (digits_start == index) {
            return .{ .value = 0, .next = self.start };
        }

        const token = self.input[self.start..index];
        const parsed = std.fmt.parseInt(i64, token, 10) catch return .{ .value = -1, .next = index };
        const value = std.math.cast(c_int, parsed) orelse -1;
        return .{ .value = value, .next = index };
    }
};

fn parseArg(input: []const u8, start: usize) ParsedArg {
    return (CsiArgParser{ .input = input, .start = start }).parse();
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
    try std.testing.expectEqual(@as(c_int, 1), st_csiprivbool(parsed.priv));
    try std.testing.expectEqual(@as(c_int, 1), parsed.narg);
    try std.testing.expectEqual(@as(c_int, 25), parsed.arg[0]);
    try std.testing.expectEqual(@as(c_char, 'h'), parsed.mode[0]);
}

test "csi private bool rejects regular sequences" {
    try std.testing.expectEqual(@as(c_int, 0), st_csiprivbool(0));
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
