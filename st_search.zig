//! search 领域状态机，不直接暴露 C ABI。
//! [输入]: 搜索输入状态、匹配数量、当前索引、UTF-8 字节序列。
//! [输出]: 搜索栏编辑、跳转、提交/取消的内部决策结果。
//! [定位]: 承载 search 相关纯逻辑，C adapter 只负责转换 extern struct。

const std = @import("std");

pub const StepPlan = struct {
    run: bool,
    current: i32,
};

pub const DeletePlan = struct {
    run: bool,
    new_len: usize,
};

pub const Action = enum(i32) {
    none = 0,
    clear = 1,
    set = 2,
    redraw = 3,
};

pub const PromptPlan = struct {
    inputmode: bool,
    inputlen: usize,
    inputcursor: usize,
    alloc: bool,
    inputcap: usize,
};

pub const SetPlan = struct {
    alloc_len: usize,
    active: bool,
    current: i32,
};

pub fn currentValid(active: bool, current: i32, nmatches: i32) bool {
    return active and current >= 0 and current < nmatches;
}

pub fn nextCurrent(old_current: i32, nmatches: i32) i32 {
    if (nmatches == 0) return -1;
    if (between(old_current, 0, nmatches - 1)) return old_current;
    return 0;
}

pub fn jumpScroll(current_valid: bool, term_scr: i32, match_scr: i32) i32 {
    if (!current_valid) return term_scr;
    return if (term_scr != match_scr) match_scr else term_scr;
}

pub fn step(active: bool, nmatches: i32, current: i32, direction: i32) StepPlan {
    if (!active or nmatches == 0) return .{ .run = false, .current = current };
    return .{
        .run = true,
        .current = @mod(current + nmatches + direction, nmatches),
    };
}

pub fn prevChar(input: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var next = cursor - 1;
    while (next > 0 and (input[next] & 0xc0) == 0x80) {
        next -= 1;
    }
    return next;
}

pub fn nextChar(input: []const u8, cursor: usize) usize {
    if (cursor >= input.len) return input.len;
    var next = cursor + 1;
    while (next < input.len and (input[next] & 0xc0) == 0x80) {
        next += 1;
    }
    return next;
}

pub fn deleteWordStart(input: []const u8, cursor: usize) usize {
    var start = cursor;
    while (start > 0 and input[prevChar(input, start)] == ' ') {
        start = prevChar(input, start);
    }
    while (start > 0 and input[prevChar(input, start)] != ' ') {
        start = prevChar(input, start);
    }
    return start;
}

pub fn inputCap(inputlen: usize, add_len: usize, inputcap: usize) usize {
    const required = inputlen + add_len + 1;
    var next_cap = inputcap;
    while (required > next_cap) {
        next_cap = if (next_cap != 0) next_cap * 2 else 64;
    }
    return next_cap;
}

pub fn inputGrow(inputlen: usize, add_len: usize, inputcap: usize) bool {
    return inputlen + add_len + 1 > inputcap;
}

pub fn inputPlan(inputmode: bool, len: usize) bool {
    return inputmode and len != 0;
}

pub fn backspacePlan(inputmode: bool, inputlen: usize, cursor: usize) bool {
    return inputmode and inputlen != 0 and cursor != 0;
}

pub fn deleteForwardPlan(inputmode: bool, cursor: usize, inputlen: usize) bool {
    return inputmode and cursor < inputlen;
}

pub fn deleteWordPlan(inputmode: bool, cursor: usize) bool {
    return inputmode and cursor != 0;
}

pub fn cursorPlan(inputmode: bool) bool {
    return inputmode;
}

pub fn scanPlan(active: bool, qlen: i32) bool {
    return active and qlen > 0;
}

pub fn deletePlan(start: usize, end: usize, inputlen: usize) DeletePlan {
    if (start >= end or end > inputlen) return .{ .run = false, .new_len = inputlen };
    return .{ .run = true, .new_len = inputlen - (end - start) };
}

pub fn commitPlan(inputmode: bool, inputlen: usize) Action {
    if (!inputmode) return .none;
    return if (inputlen == 0) .clear else .set;
}

pub fn cancelPlan(inputmode: bool) Action {
    return if (inputmode) .redraw else .none;
}

pub fn clearInputPlan(inputmode: bool) bool {
    return inputmode;
}

pub fn barActive(inputmode: bool, active: bool) bool {
    return inputmode or active;
}

pub fn promptPlan(has_input: bool, inputcap: usize) PromptPlan {
    return .{
        .inputmode = true,
        .inputlen = 0,
        .inputcursor = 0,
        .alloc = !has_input,
        .inputcap = if (!has_input) 64 else inputcap,
    };
}

pub fn setPlan(query_len: usize, qlen: i32) SetPlan {
    return .{
        .alloc_len = if (query_len != 0) query_len else 1,
        .active = qlen > 0,
        .current = -1,
    };
}

pub fn matchCap(nmatches: i32, cap: i32) i32 {
    if (nmatches != cap) return cap;
    return if (cap != 0) cap * 2 else 16;
}

fn between(value: i32, lower: i32, upper: i32) bool {
    return lower <= value and value <= upper;
}

test "search current and step plans handle bounds" {
    try std.testing.expect(currentValid(true, 0, 1));
    try std.testing.expect(!currentValid(false, 0, 1));
    try std.testing.expect(!currentValid(true, 2, 1));
    try std.testing.expectEqual(@as(i32, -1), nextCurrent(2, 0));
    try std.testing.expectEqual(@as(i32, 2), nextCurrent(2, 5));
    try std.testing.expectEqual(@as(i32, 0), nextCurrent(8, 5));
    try std.testing.expectEqual(@as(i32, 3), jumpScroll(true, 0, 3));
    try std.testing.expectEqual(@as(i32, 0), jumpScroll(false, 0, 3));
    try std.testing.expectEqual(@as(i32, 0), step(true, 3, 2, 1).current);
    try std.testing.expectEqual(@as(i32, 2), step(true, 3, 0, -1).current);
    try std.testing.expect(!step(false, 3, 1, 1).run);
}

test "search utf8 cursor and delete word plans" {
    const input = "abc  你好";

    try std.testing.expectEqual(@as(usize, 5), deleteWordStart(input, input.len));
    try std.testing.expectEqual(@as(usize, 8), prevChar(input, input.len));
    try std.testing.expectEqual(@as(usize, 8), nextChar(input, 5));
}

test "search input edit plans guard inactive states" {
    try std.testing.expectEqual(@as(usize, 64), inputCap(0, 3, 0));
    try std.testing.expectEqual(@as(usize, 128), inputCap(63, 2, 64));
    try std.testing.expect(!inputGrow(3, 2, 8));
    try std.testing.expect(inputGrow(7, 2, 8));
    try std.testing.expect(!inputPlan(false, 3));
    try std.testing.expect(!inputPlan(true, 0));
    try std.testing.expect(inputPlan(true, 3));
    try std.testing.expect(!backspacePlan(true, 3, 0));
    try std.testing.expect(backspacePlan(true, 3, 2));
    try std.testing.expect(!deleteForwardPlan(true, 3, 3));
    try std.testing.expect(deleteForwardPlan(true, 2, 3));
    try std.testing.expect(!deleteWordPlan(true, 0));
    try std.testing.expect(cursorPlan(true));
    try std.testing.expect(scanPlan(true, 2));
}

test "search commit prompt and match capacity plans" {
    try std.testing.expect(deletePlan(2, 5, 9).run);
    try std.testing.expectEqual(@as(usize, 6), deletePlan(2, 5, 9).new_len);
    try std.testing.expect(!deletePlan(5, 2, 9).run);
    try std.testing.expectEqual(Action.none, commitPlan(false, 1));
    try std.testing.expectEqual(Action.clear, commitPlan(true, 0));
    try std.testing.expectEqual(Action.set, commitPlan(true, 3));
    try std.testing.expectEqual(Action.redraw, cancelPlan(true));
    try std.testing.expect(clearInputPlan(true));
    try std.testing.expect(!clearInputPlan(false));
    try std.testing.expect(barActive(true, false));
    try std.testing.expect(barActive(false, true));
    try std.testing.expect(!barActive(false, false));

    const missing = promptPlan(false, 0);
    const existing = promptPlan(true, 128);
    try std.testing.expect(missing.inputmode);
    try std.testing.expect(missing.alloc);
    try std.testing.expectEqual(@as(usize, 64), missing.inputcap);
    try std.testing.expect(!existing.alloc);
    try std.testing.expectEqual(@as(usize, 128), existing.inputcap);

    const empty = setPlan(0, 0);
    const active = setPlan(6, 2);
    try std.testing.expectEqual(@as(usize, 1), empty.alloc_len);
    try std.testing.expect(!empty.active);
    try std.testing.expect(active.active);
    try std.testing.expectEqual(@as(i32, -1), active.current);
    try std.testing.expectEqual(@as(i32, 16), matchCap(0, 0));
    try std.testing.expectEqual(@as(i32, 32), matchCap(16, 16));
    try std.testing.expectEqual(@as(i32, 16), matchCap(3, 16));
}
