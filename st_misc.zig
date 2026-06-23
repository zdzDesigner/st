//! st_misc.zig 负责 CSI 杂项序列的纯规划。
//! [输入]: CSI 主 mode、第二 mode 字节、参数数组和 DEC 测试 selector。
//! [输出]: `ZigMiscPlan` 或是否执行 DEC alignment test。
//! [副作用边界]: 不调用 `tdump(...)`、`tputc(...)`、`xsetcursor(...)`；C 侧根据 plan 执行真实动作。
//! [定位]: 收敛 `csihandle(...)` 中 `i/b/space` 分支。

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

const MiscCommand = struct {
    mode0: c_char,
    mode1: c_char,
    args: []const c_int,

    fn plan(self: MiscCommand) ZigMiscPlan {
        const arg0 = defaultArg(self.args, 0, 0);

        return switch (self.mode0) {
            'i' => switch (arg0) {
                0 => .{ .kind = misc_media_dump, .value = 0, .extra = 0 },
                1 => .{ .kind = misc_media_dump_line, .value = 0, .extra = 0 },
                2 => .{ .kind = misc_media_dump_sel, .value = 0, .extra = 0 },
                4 => .{ .kind = misc_media_print_off, .value = 0, .extra = 0 },
                5 => .{ .kind = misc_media_print_on, .value = 0, .extra = 0 },
                else => .{ .kind = misc_none, .value = 0, .extra = 0 },
            },
            'b' => .{ .kind = misc_repeat_last, .value = countArg(self.args), .extra = 0 },
            ' ' => if (self.mode1 == 'q')
                .{ .kind = misc_set_cursor_style, .value = arg0, .extra = 0 }
            else
                .{ .kind = misc_unknown, .value = 0, .extra = 0 },
            else => .{ .kind = misc_unknown, .value = 0, .extra = 0 },
        };
    }
};

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

fn planMisc(mode0: c_char, mode1: c_char, arg: [*]const c_int, len: c_int) ZigMiscPlan {
    const args = arg[0..@intCast(len)];
    return (MiscCommand{ .mode0 = mode0, .mode1 = mode1, .args = args }).plan();
}

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

fn defaultArg(args: []const c_int, index: usize, fallback: c_int) c_int {
    if (index >= args.len) return fallback;
    return args[index];
}

fn countArg(args: []const c_int) c_int {
    const value = defaultArg(args, 0, 0);
    return if (value == 0) 1 else value;
}

test "plan media copy 0 dumps all" {
    const plan = planMisc('i', 0, &[_]c_int{0}, 1);
    try std.testing.expectEqual(@as(c_int, misc_media_dump), plan.kind);
}

test "plan media copy 5 enables print mode" {
    const plan = planMisc('i', 0, &[_]c_int{5}, 1);
    try std.testing.expectEqual(@as(c_int, misc_media_print_on), plan.kind);
}

test "plan repeat defaults to one" {
    const plan = planMisc('b', 0, &[_]c_int{0}, 1);
    try std.testing.expectEqual(@as(c_int, misc_repeat_last), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.value);
}

test "plan cursor style uses q suffix" {
    const plan = planMisc(' ', 'q', &[_]c_int{3}, 1);
    try std.testing.expectEqual(@as(c_int, misc_set_cursor_style), plan.kind);
    try std.testing.expectEqual(@as(c_int, 3), plan.value);
}

test "plan space with unsupported suffix is unknown" {
    const plan = planMisc(' ', 'x', &[_]c_int{3}, 1);
    try std.testing.expectEqual(@as(c_int, misc_unknown), plan.kind);
}

test "plan media copy unsupported arg is none" {
    const plan = planMisc('i', 0, &[_]c_int{9}, 1);
    try std.testing.expectEqual(@as(c_int, misc_none), plan.kind);
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
