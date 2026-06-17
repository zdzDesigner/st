//! st_base64.zig 是 `base64dec(...)` 的 Zig 迁移入口。
//! [输入]: C 侧传入以 NUL 结尾的 base64 字符串。
//! [输出]: 返回由 Zig 分配并以 NUL 结尾的解码字符串，失败时返回 null。
//! [副作用边界]: 这里只负责解码和结果分配；调用方仍在 C 侧决定如何使用、释放或写入 X selection。
//! [定位]: 这是字符串处理辅助模块，不直接访问 `term`、`sel` 或 X11 状态。

const std = @import("std");

const allocator = std.heap.c_allocator;

export fn st_base64dec(src: [*:0]const u8) ?[*:0]u8 {
    return (Base64Decoder{ .input = .{ .bytes = std.mem.span(src) } }).decodeZ();
}

const Base64Input = struct {
    bytes: []const u8,

    fn printableLen(self: Base64Input) usize {
        var count: usize = 0;
        for (self.bytes) |c| {
            if (std.ascii.isPrint(c)) count += 1;
        }
        return count;
    }

    fn paddedLen(self: Base64Input) usize {
        const len = self.printableLen();
        if (len % 4 == 0) return len;
        return len + 4 - (len % 4);
    }

    fn sanitize(self: Base64Input, out: []u8) void {
        var idx: usize = 0;
        for (self.bytes) |c| {
            if (!std.ascii.isPrint(c)) continue;
            out[idx] = c;
            idx += 1;
        }
        while (idx < out.len) : (idx += 1) {
            out[idx] = '=';
        }
    }
};

const Base64Decoder = struct {
    input: Base64Input,

    fn decodeZ(self: Base64Decoder) ?[*:0]u8 {
        const decoder = std.base64.standard.Decoder;
        const sanitized = allocator.alloc(u8, self.input.paddedLen()) catch return null;
        defer allocator.free(sanitized);

        self.input.sanitize(sanitized);

        const decoded_len = decoder.calcSizeForSlice(sanitized) catch return null;
        const result = allocator.alloc(u8, decoded_len + 1) catch return null;
        errdefer allocator.free(result);

        decoder.decode(result[0..decoded_len], sanitized) catch return null;
        result[decoded_len] = 0;

        return @ptrCast(result.ptr);
    }
};

fn countPrintable(input: []const u8) usize {
    return (Base64Input{ .bytes = input }).printableLen();
}

fn paddingLen(len: usize) usize {
    if (len % 4 == 0) return 0;
    return 4 - (len % 4);
}

fn sanitizeAndPad(input: []const u8, sanitized: []u8) void {
    (Base64Input{ .bytes = input }).sanitize(sanitized);
}

test "base64 decode valid input" {
    const input = "SGVsbG8=";
    const result = st_base64dec(input) orelse return error.UnexpectedNull;
    defer allocator.free(std.mem.span(result)[0 .. std.mem.span(result).len + 1]);

    try std.testing.expectEqualStrings("Hello", std.mem.span(result));
}

test "base64 decode ignores non printable bytes" {
    const result = st_base64dec("SGVs\nbG8=") orelse return error.UnexpectedNull;
    defer allocator.free(std.mem.span(result)[0 .. std.mem.span(result).len + 1]);

    try std.testing.expectEqualStrings("Hello", std.mem.span(result));
}

test "base64 decode accepts missing padding" {
    const result = st_base64dec("SGVsbG8") orelse return error.UnexpectedNull;
    defer allocator.free(std.mem.span(result)[0 .. std.mem.span(result).len + 1]);

    try std.testing.expectEqualStrings("Hello", std.mem.span(result));
}

test "base64 decode invalid printable input returns null" {
    try std.testing.expectEqual(@as(?[*:0]u8, null), st_base64dec("%%%"));
}
