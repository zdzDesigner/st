const std = @import("std");

const allocator = std.heap.c_allocator;

export fn st_base64dec(src: [*:0]const u8) ?[*:0]u8 {
    const input = std.mem.span(src);
    const decoder = std.base64.standard.Decoder;
    const printable_len = countPrintable(input);
    const padded_len = printable_len + paddingLen(printable_len);
    const sanitized = allocator.alloc(u8, padded_len) catch return null;
    defer allocator.free(sanitized);

    sanitizeAndPad(input, sanitized);

    const decoded_len = decoder.calcSizeForSlice(sanitized) catch return null;
    const result = allocator.alloc(u8, decoded_len + 1) catch return null;
    errdefer allocator.free(result);

    decoder.decode(result[0..decoded_len], sanitized) catch return null;
    result[decoded_len] = 0;

    return @ptrCast(result.ptr);
}

fn countPrintable(input: []const u8) usize {
    var count: usize = 0;
    for (input) |c| {
        if (std.ascii.isPrint(c)) count += 1;
    }
    return count;
}

fn paddingLen(len: usize) usize {
    if (len % 4 == 0) return 0;
    return 4 - (len % 4);
}

fn sanitizeAndPad(input: []const u8, sanitized: []u8) void {
    var idx: usize = 0;
    for (input) |c| {
        if (!std.ascii.isPrint(c)) continue;
        sanitized[idx] = c;
        idx += 1;
    }
    while (idx < sanitized.len) : (idx += 1) {
        sanitized[idx] = '=';
    }
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
