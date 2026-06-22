//! search 领域状态机，不直接暴露 C ABI。
//! [输入]: 搜索输入状态、匹配数量、当前索引、UTF-8 字节序列。
//! [输出]: 搜索栏编辑、跳转、提交/取消的内部决策结果。
//! [定位]: 承载 search 相关纯逻辑，C adapter 只负责转换 extern struct。

const std = @import("std");
const model = @import("term_model.zig");

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

pub const Hit = struct {
    active: bool,
    match_scr: i32,
    term_scr: i32,
    match_y: i32,
    y: i32,
    x: i32,
    match_x: i32,
    match_len: i32,

    pub fn contains(self: Hit) bool {
        return self.active and self.match_scr == self.term_scr and self.match_y == self.y and between(self.x, self.match_x, self.match_x + self.match_len - 1);
    }
};

pub const Matches = struct {
    active: bool,
    current: i32,
    count: i32,

    pub fn currentValid(self: Matches) bool {
        return self.active and self.current >= 0 and self.current < self.count;
    }

    pub fn nextCurrent(self: Matches) i32 {
        if (self.count == 0) return -1;
        if (between(self.current, 0, self.count - 1)) return self.current;
        return 0;
    }

    pub fn step(self: Matches, direction: i32) StepPlan {
        if (!self.active or self.count == 0) return .{ .run = false, .current = self.current };
        return .{
            .run = true,
            .current = @mod(self.current + self.count + direction, self.count),
        };
    }

    pub fn nextCap(self: Matches, cap: i32) i32 {
        if (self.count != cap) return cap;
        return if (cap != 0) cap * 2 else 16;
    }
};

pub const Jump = struct {
    current_valid: bool,
    term_scr: i32,
    match_scr: i32,

    pub fn scroll(self: Jump) i32 {
        if (!self.current_valid) return self.term_scr;
        return if (self.term_scr != self.match_scr) self.match_scr else self.term_scr;
    }
};

pub const History = struct {
    head: i32,
    size: i32,

    pub fn index(self: History, scroll: i32) i32 {
        return @mod(self.head - scroll + self.size + 1, self.size);
    }
};

pub const Input = struct {
    active: bool,
    len: usize,
    cursor: usize,
    cap: usize,

    pub fn nextCap(self: Input, add_len: usize) usize {
        const required = self.len + add_len + 1;
        var next_cap = self.cap;
        while (required > next_cap) {
            next_cap = if (next_cap != 0) next_cap * 2 else 64;
        }
        return next_cap;
    }

    pub fn needsGrow(self: Input, add_len: usize) bool {
        return self.len + add_len + 1 > self.cap;
    }

    pub fn insertable(self: Input) bool {
        return self.active and self.len != 0;
    }

    pub fn canBackspace(self: Input) bool {
        return self.active and self.len != 0 and self.cursor != 0;
    }

    pub fn canDeleteForward(self: Input) bool {
        return self.active and self.cursor < self.len;
    }

    pub fn canDeleteWord(self: Input) bool {
        return self.active and self.cursor != 0;
    }

    pub fn showsCursor(self: Input) bool {
        return self.active;
    }

    pub fn deleteRange(self: Input, start: usize, end: usize) DeletePlan {
        if (start >= end or end > self.len) return .{ .run = false, .new_len = self.len };
        return .{ .run = true, .new_len = self.len - (end - start) };
    }

    pub fn commit(self: Input) Action {
        if (!self.active) return .none;
        return if (self.len == 0) .clear else .set;
    }

    pub fn cancel(self: Input) Action {
        return if (self.active) .redraw else .none;
    }

    pub fn clearable(self: Input) bool {
        return self.active;
    }

    pub fn barActive(self: Input, search_active: bool) bool {
        return self.active or search_active;
    }
};

pub const InputBytes = struct {
    bytes: []const u8,

    pub fn prevChar(self: InputBytes, cursor: usize) usize {
        if (cursor == 0) return 0;
        var next = cursor - 1;
        while (next > 0 and (self.bytes[next] & 0xc0) == 0x80) {
            next -= 1;
        }
        return next;
    }

    pub fn nextChar(self: InputBytes, cursor: usize) usize {
        if (cursor >= self.bytes.len) return self.bytes.len;
        var next = cursor + 1;
        while (next < self.bytes.len and (self.bytes[next] & 0xc0) == 0x80) {
            next += 1;
        }
        return next;
    }

    pub fn deleteWordStart(self: InputBytes, cursor: usize) usize {
        var start = cursor;
        while (start > 0 and self.bytes[self.prevChar(start)] == ' ') {
            start = self.prevChar(start);
        }
        while (start > 0 and self.bytes[self.prevChar(start)] != ' ') {
            start = self.prevChar(start);
        }
        return start;
    }
};

pub fn LineMatcher(comptime Glyph: type) type {
    return struct {
        line: []const Glyph,
        linelen: i32,
        cols: i32,

        const Self = @This();

        pub fn match(self: Self, x: i32, query: []const u32) i32 {
            if (x < 0 or x >= self.linelen or x >= self.cols or self.line.len == 0) return 0;

            if (model.hasWideDummy(self.line[@intCast(x)].mode)) return 0;

            var pos = x;
            var query_pos: usize = 0;
            while (query_pos < query.len) : (query_pos += 1) {
                while (pos < self.linelen and model.hasWideDummy(self.line[@intCast(pos)].mode)) {
                    pos += 1;
                }
                if (pos >= self.linelen or self.line[@intCast(pos)].u != query[query_pos]) return 0;
                pos += 1;
            }
            while (pos < self.cols and model.hasWideDummy(self.line[@intCast(pos)].mode)) {
                pos += 1;
            }
            return pos - x;
        }
    };
}

pub fn hit(active: bool, match_scr: i32, term_scr: i32, match_y: i32, y: i32, x: i32, match_x: i32, match_len: i32) bool {
    return (Hit{ .active = active, .match_scr = match_scr, .term_scr = term_scr, .match_y = match_y, .y = y, .x = x, .match_x = match_x, .match_len = match_len }).contains();
}

pub fn lineMatch(comptime Glyph: type, line: []const Glyph, x: i32, linelen: i32, query: []const u32, cols: i32) i32 {
    return (LineMatcher(Glyph){ .line = line, .linelen = linelen, .cols = cols }).match(x, query);
}

pub fn currentValid(active: bool, current: i32, nmatches: i32) bool {
    return (Matches{ .active = active, .current = current, .count = nmatches }).currentValid();
}

pub fn nextCurrent(old_current: i32, nmatches: i32) i32 {
    return (Matches{ .active = true, .current = old_current, .count = nmatches }).nextCurrent();
}

pub fn jumpScroll(current_valid: bool, term_scr: i32, match_scr: i32) i32 {
    return (Jump{ .current_valid = current_valid, .term_scr = term_scr, .match_scr = match_scr }).scroll();
}

pub fn historyIndex(head: i32, scroll: i32, size: i32) i32 {
    return (History{ .head = head, .size = size }).index(scroll);
}

pub fn step(active: bool, nmatches: i32, current: i32, direction: i32) StepPlan {
    return (Matches{ .active = active, .current = current, .count = nmatches }).step(direction);
}

pub fn prevChar(input: []const u8, cursor: usize) usize {
    return (InputBytes{ .bytes = input }).prevChar(cursor);
}

pub fn nextChar(input: []const u8, cursor: usize) usize {
    return (InputBytes{ .bytes = input }).nextChar(cursor);
}

pub fn deleteWordStart(input: []const u8, cursor: usize) usize {
    return (InputBytes{ .bytes = input }).deleteWordStart(cursor);
}

pub fn inputCap(inputlen: usize, add_len: usize, inputcap: usize) usize {
    return (Input{ .active = true, .len = inputlen, .cursor = 0, .cap = inputcap }).nextCap(add_len);
}

pub fn inputGrow(inputlen: usize, add_len: usize, inputcap: usize) bool {
    return (Input{ .active = true, .len = inputlen, .cursor = 0, .cap = inputcap }).needsGrow(add_len);
}

pub fn inputPlan(inputmode: bool, len: usize) bool {
    return (Input{ .active = inputmode, .len = len, .cursor = 0, .cap = 0 }).insertable();
}

pub fn backspacePlan(inputmode: bool, inputlen: usize, cursor: usize) bool {
    return (Input{ .active = inputmode, .len = inputlen, .cursor = cursor, .cap = 0 }).canBackspace();
}

pub fn deleteForwardPlan(inputmode: bool, cursor: usize, inputlen: usize) bool {
    return (Input{ .active = inputmode, .len = inputlen, .cursor = cursor, .cap = 0 }).canDeleteForward();
}

pub fn deleteWordPlan(inputmode: bool, cursor: usize) bool {
    return (Input{ .active = inputmode, .len = 0, .cursor = cursor, .cap = 0 }).canDeleteWord();
}

pub fn cursorPlan(inputmode: bool) bool {
    return (Input{ .active = inputmode, .len = 0, .cursor = 0, .cap = 0 }).showsCursor();
}

pub fn scanPlan(active: bool, qlen: i32) bool {
    return active and qlen > 0;
}

pub fn deletePlan(start: usize, end: usize, inputlen: usize) DeletePlan {
    return (Input{ .active = true, .len = inputlen, .cursor = 0, .cap = 0 }).deleteRange(start, end);
}

pub fn commitPlan(inputmode: bool, inputlen: usize) Action {
    return (Input{ .active = inputmode, .len = inputlen, .cursor = 0, .cap = 0 }).commit();
}

pub fn cancelPlan(inputmode: bool) Action {
    return (Input{ .active = inputmode, .len = 0, .cursor = 0, .cap = 0 }).cancel();
}

pub fn clearInputPlan(inputmode: bool) bool {
    return (Input{ .active = inputmode, .len = 0, .cursor = 0, .cap = 0 }).clearable();
}

pub fn barActive(inputmode: bool, active: bool) bool {
    return (Input{ .active = inputmode, .len = 0, .cursor = 0, .cap = 0 }).barActive(active);
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
    return (Matches{ .active = true, .current = 0, .count = nmatches }).nextCap(cap);
}

fn between(value: i32, lower: i32, upper: i32) bool {
    return lower <= value and value <= upper;
}

test "search hit and line match scan glyphs" {
    const Glyph = struct { u: u32, mode: u16 };
    const line = [_]Glyph{
        .{ .u = 'a', .mode = 0 },
        .{ .u = 'x', .mode = model.attr_wdummy },
        .{ .u = 'b', .mode = 0 },
        .{ .u = 'c', .mode = 0 },
    };
    const query = [_]u32{ 'a', 'b', 'c' };

    try std.testing.expect(hit(true, 2, 2, 4, 4, 7, 5, 3));
    try std.testing.expect(!hit(true, 2, 2, 4, 4, 9, 5, 3));
    try std.testing.expectEqual(@as(i32, 4), lineMatch(Glyph, &line, 0, line.len, &query, line.len));
    try std.testing.expectEqual(@as(i32, 0), lineMatch(Glyph, &line, 1, line.len, &query, line.len));
}

test "search line matcher rejects out of range starts" {
    const Glyph = struct { u: u32, mode: u16 };
    const line = [_]Glyph{.{ .u = '中', .mode = 0 }};
    const query = [_]u32{'中'};

    try std.testing.expectEqual(@as(i32, 0), lineMatch(Glyph, &line, -1, line.len, &query, line.len));
    try std.testing.expectEqual(@as(i32, 0), lineMatch(Glyph, &line, 1, line.len, &query, line.len));
    try std.testing.expectEqual(@as(i32, 0), lineMatch(Glyph, &line, 0, 0, &query, line.len));
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

test "search history index wraps ring buffer" {
    try std.testing.expectEqual(@as(i32, 6), historyIndex(7, 2, 10));
    try std.testing.expectEqual(@as(i32, 9), historyIndex(0, 2, 10));
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
