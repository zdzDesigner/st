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

pub const InsertPlan = struct {
    run: bool,
    grow: bool,
    inputcap: usize,
    insert_at: usize,
    move_dst: usize,
    move_src: usize,
    move_len: usize,
    new_len: usize,
    new_cursor: usize,
};

pub const CursorEditKind = enum(i32) {
    none = 0,
    delete = 1,
    move = 2,
};

pub const DeleteEdit = struct {
    start: usize,
    end: usize,
    cursor: usize,
};

pub const CursorEdit = union(CursorEditKind) {
    none,
    delete: DeleteEdit,
    move: usize,
};

pub const StateEditKind = enum(i32) {
    none = 0,
    clear_input = 1,
    commit_clear = 2,
    commit_set = 3,
    cancel = 4,
};

pub const ResetInput = struct {
    len: usize,
    cursor: usize,
};

pub const StateEdit = union(StateEditKind) {
    none,
    clear_input: ResetInput,
    commit_clear,
    commit_set,
    cancel,
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

pub const SearchSnapshot = struct {
    query_len: i32,
    inputmode: bool,
    inputlen: usize,
    inputcursor: usize,
    inputcap: usize,
    nmatches: i32,
    match_cap: i32,
    current: i32,
    active: bool,
};

pub const SearchStateUpdate = struct {
    active: bool,
    current: i32,
    inputmode: bool,
    inputlen: usize,
    inputcursor: usize,
    inputcap: usize,
    nmatches: i32,
    match_cap: i32,
};

pub const SearchEffectPlan = struct {
    alloc_input: bool,
    realloc_input: bool,
    alloc_query: bool,
    realloc_matches: bool,
    clear_query: bool,
    clear_matches: bool,
    refresh_search: bool,
    redraw: bool,
    jump: bool,
};

pub const SearchPromptResult = struct {
    update: SearchStateUpdate,
    effect: SearchEffectPlan,
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

pub const SearchMatch = extern struct {
    x: i32,
    y: i32,
    scr: i32,
    len: i32,

    pub fn hit(self: SearchMatch, active: bool, term_scr: i32, x: i32, y: i32) bool {
        return (Hit{ .active = active, .match_scr = self.scr, .term_scr = term_scr, .match_y = self.y, .y = y, .x = x, .match_x = self.x, .match_len = self.len }).contains();
    }
};

pub const ScanLine = struct {
    linelen: i32,
    query_len: i32,

    pub fn lastStart(self: ScanLine) i32 {
        return self.linelen - self.query_len;
    }
};

pub const MatchAppendKind = enum(i32) {
    skip = 0,
    append = 1,
    grow_append = 2,
};

pub const GrowAppend = struct {
    cap: i32,
    match: SearchMatch,
};

pub const MatchAppend = union(MatchAppendKind) {
    skip,
    append: SearchMatch,
    grow_append: GrowAppend,
};

pub const MatchList = struct {
    matches: []const SearchMatch,
    active: bool,
    current: i32,

    pub fn contains(self: MatchList, term_scr: i32, x: i32, y: i32) bool {
        for (self.matches) |match| {
            if (match.hit(self.active, term_scr, x, y)) return true;
        }
        return false;
    }

    pub fn containsCurrent(self: MatchList, term_scr: i32, x: i32, y: i32) bool {
        if (!(Matches{ .active = self.active, .current = self.current, .count = @intCast(self.matches.len) }).currentValid()) return false;
        return self.matches[@intCast(self.current)].hit(self.active, term_scr, x, y);
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

    pub fn append(self: Matches, match_len: i32, x: i32, y: i32, scr: i32, cap: i32) MatchAppend {
        if (match_len == 0) return .skip;
        const match = SearchMatch{ .x = x, .y = y, .scr = scr, .len = match_len };
        const next_cap = self.nextCap(cap);
        if (next_cap != cap) return .{ .grow_append = .{ .cap = next_cap, .match = match } };
        return .{ .append = match };
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

    pub fn visibleIndex(self: History, y: i32, scroll: i32) i32 {
        return @mod(y + self.head - scroll + self.size + 1, self.size);
    }
};

pub const HistoryLine = struct {
    hist: bool,
    index: i32,
};

pub const HistoryView = struct {
    histsize: i32,
    rows: i32,

    pub fn line(self: HistoryView, y: i32) HistoryLine {
        const last_hist = self.histsize - self.rows + 2;
        if (y <= last_hist) return .{ .hist = true, .index = y };
        return .{ .hist = false, .index = y - self.histsize + self.rows - 3 };
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
        return self.active;
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

    pub fn insertPlan(self: Input, add_len: usize) InsertPlan {
        if (!self.insertable()) {
            return .{
                .run = false,
                .grow = false,
                .inputcap = self.cap,
                .insert_at = self.cursor,
                .move_dst = self.cursor,
                .move_src = self.cursor,
                .move_len = 0,
                .new_len = self.len,
                .new_cursor = self.cursor,
            };
        }

        const grow = self.needsGrow(add_len);
        return .{
            .run = true,
            .grow = grow,
            .inputcap = if (grow) self.nextCap(add_len) else self.cap,
            .insert_at = self.cursor,
            .move_dst = self.cursor + add_len,
            .move_src = self.cursor,
            .move_len = self.len - self.cursor + 1,
            .new_len = self.len + add_len,
            .new_cursor = self.cursor + add_len,
        };
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

    pub fn clearEdit(self: Input) StateEdit {
        if (!self.clearable()) return .none;
        return .{ .clear_input = .{ .len = 0, .cursor = 0 } };
    }

    pub fn commitEdit(self: Input) StateEdit {
        return switch (self.commit()) {
            .none => .none,
            .clear => .commit_clear,
            .set => .commit_set,
            .redraw => .none,
        };
    }

    pub fn cancelEdit(self: Input) StateEdit {
        return switch (self.cancel()) {
            .none => .none,
            .redraw => .cancel,
            .clear, .set => .none,
        };
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

pub const InputEditor = struct {
    input: Input,
    bytes: InputBytes,

    pub fn backspace(self: InputEditor) CursorEdit {
        if (!self.input.canBackspace()) return .none;
        const prev = self.bytes.prevChar(self.input.cursor);
        return .{ .delete = .{ .start = prev, .end = self.input.cursor, .cursor = prev } };
    }

    pub fn deleteForward(self: InputEditor) CursorEdit {
        if (!self.input.canDeleteForward()) return .none;
        return .{ .delete = .{ .start = self.input.cursor, .end = self.bytes.nextChar(self.input.cursor), .cursor = self.input.cursor } };
    }

    pub fn deleteWord(self: InputEditor) CursorEdit {
        if (!self.input.canDeleteWord()) return .none;
        const start = self.bytes.deleteWordStart(self.input.cursor);
        return .{ .delete = .{ .start = start, .end = self.input.cursor, .cursor = start } };
    }

    pub fn moveLeft(self: InputEditor) CursorEdit {
        if (!self.input.canBackspace()) return .none;
        return .{ .move = self.bytes.prevChar(self.input.cursor) };
    }

    pub fn moveRight(self: InputEditor) CursorEdit {
        if (!self.input.canDeleteForward()) return .none;
        return .{ .move = self.bytes.nextChar(self.input.cursor) };
    }

    pub fn home(self: InputEditor) CursorEdit {
        if (!self.input.showsCursor()) return .none;
        return .{ .move = 0 };
    }

    pub fn end(self: InputEditor) CursorEdit {
        if (!self.input.showsCursor()) return .none;
        return .{ .move = self.input.len };
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

pub fn matchListContains(matches: []const SearchMatch, active: bool, current: i32, term_scr: i32, x: i32, y: i32) bool {
    _ = current;
    return (MatchList{ .matches = matches, .active = active, .current = -1 }).contains(term_scr, x, y);
}

pub fn matchListCurrent(matches: []const SearchMatch, active: bool, current: i32, term_scr: i32, x: i32, y: i32) bool {
    return (MatchList{ .matches = matches, .active = active, .current = current }).containsCurrent(term_scr, x, y);
}

pub fn scanLineLastStart(linelen: i32, query_len: i32) i32 {
    return (ScanLine{ .linelen = linelen, .query_len = query_len }).lastStart();
}

pub fn appendMatch(match_len: i32, nmatches: i32, cap: i32, x: i32, y: i32, scr: i32) MatchAppend {
    return (Matches{ .active = true, .current = 0, .count = nmatches }).append(match_len, x, y, scr, cap);
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

pub fn visibleHistoryIndex(y: i32, head: i32, scroll: i32, size: i32) i32 {
    return (History{ .head = head, .size = size }).visibleIndex(y, scroll);
}

pub fn historyLine(y: i32, histsize: i32, rows: i32) HistoryLine {
    return (HistoryView{ .histsize = histsize, .rows = rows }).line(y);
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

pub fn cursorEdit(input: []const u8, inputmode: bool, inputlen: usize, cursor: usize, comptime action: enum { backspace, delete_forward, delete_word, move_left, move_right, home, end }) CursorEdit {
    const editor = InputEditor{
        .input = .{ .active = inputmode, .len = inputlen, .cursor = cursor, .cap = 0 },
        .bytes = .{ .bytes = input },
    };
    return switch (action) {
        .backspace => editor.backspace(),
        .delete_forward => editor.deleteForward(),
        .delete_word => editor.deleteWord(),
        .move_left => editor.moveLeft(),
        .move_right => editor.moveRight(),
        .home => editor.home(),
        .end => editor.end(),
    };
}

pub fn insertPlan(inputmode: bool, inputlen: usize, cursor: usize, inputcap: usize, add_len: usize) InsertPlan {
    return (Input{ .active = inputmode, .len = inputlen, .cursor = cursor, .cap = inputcap }).insertPlan(add_len);
}

pub fn scanPlan(active: bool, qlen: i32) bool {
    return active and qlen > 0;
}

pub fn deletePlan(start: usize, end: usize, inputlen: usize) DeletePlan {
    return (Input{ .active = true, .len = inputlen, .cursor = 0, .cap = 0 }).deleteRange(start, end);
}

pub fn clearInputEdit(inputmode: bool) StateEdit {
    return (Input{ .active = inputmode, .len = 0, .cursor = 0, .cap = 0 }).clearEdit();
}

pub fn commitEdit(inputmode: bool, inputlen: usize) StateEdit {
    return (Input{ .active = inputmode, .len = inputlen, .cursor = 0, .cap = 0 }).commitEdit();
}

pub fn cancelEdit(inputmode: bool) StateEdit {
    return (Input{ .active = inputmode, .len = 0, .cursor = 0, .cap = 0 }).cancelEdit();
}

pub fn barActive(inputmode: bool, active: bool) bool {
    return (Input{ .active = inputmode, .len = 0, .cursor = 0, .cap = 0 }).barActive(active);
}

pub fn inputActive(inputmode: bool) bool {
    return (Input{ .active = inputmode, .len = 0, .cursor = 0, .cap = 0 }).showsCursor();
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

pub fn promptResult(snapshot: SearchSnapshot) SearchPromptResult {
    const plan = promptPlan(snapshot.inputcap != 0, snapshot.inputcap);
    return .{
        .update = .{
            .active = snapshot.active,
            .current = snapshot.current,
            .inputmode = plan.inputmode,
            .inputlen = plan.inputlen,
            .inputcursor = plan.inputcursor,
            .inputcap = plan.inputcap,
            .nmatches = snapshot.nmatches,
            .match_cap = snapshot.match_cap,
        },
        .effect = .{
            .alloc_input = plan.alloc,
            .realloc_input = false,
            .alloc_query = false,
            .realloc_matches = false,
            .clear_query = false,
            .clear_matches = false,
            .refresh_search = false,
            .redraw = true,
            .jump = false,
        },
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
    const matches = [_]SearchMatch{
        .{ .x = 5, .y = 4, .scr = 2, .len = 3 },
        .{ .x = 1, .y = 0, .scr = 0, .len = 2 },
    };

    try std.testing.expect(hit(true, 2, 2, 4, 4, 7, 5, 3));
    try std.testing.expect(!hit(true, 2, 2, 4, 4, 9, 5, 3));
    try std.testing.expect(matchListContains(&matches, true, -1, 2, 7, 4));
    try std.testing.expect(!matchListContains(&matches, true, -1, 2, 9, 4));
    try std.testing.expect(matchListCurrent(&matches, true, 1, 0, 2, 0));
    try std.testing.expect(!matchListCurrent(&matches, true, 9, 0, 2, 0));
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

test "search scan line and append decisions use typed actions" {
    const skip = appendMatch(0, 0, 0, 2, 3, 4);
    const append = appendMatch(2, 1, 4, 2, 3, 4);
    const grow = appendMatch(2, 4, 4, 2, 3, 4);

    try std.testing.expectEqual(@as(i32, 7), scanLineLastStart(10, 3));
    try std.testing.expectEqual(MatchAppend.skip, skip);
    try std.testing.expectEqual(@as(i32, 2), append.append.x);
    try std.testing.expectEqual(@as(i32, 3), append.append.y);
    try std.testing.expectEqual(@as(i32, 4), append.append.scr);
    try std.testing.expectEqual(@as(i32, 2), append.append.len);
    try std.testing.expectEqual(@as(i32, 8), grow.grow_append.cap);
    try std.testing.expectEqual(@as(i32, 2), grow.grow_append.match.len);
}

test "search history index wraps ring buffer" {
    try std.testing.expectEqual(@as(i32, 6), historyIndex(7, 2, 10));
    try std.testing.expectEqual(@as(i32, 9), historyIndex(0, 2, 10));
    try std.testing.expectEqual(@as(i32, 4), visibleHistoryIndex(3, 7, 7, 10));
    try std.testing.expectEqual(@as(i32, 9), visibleHistoryIndex(0, 0, 2, 10));
}

test "search history line maps external pipe rows" {
    const hist_line = historyLine(5, 10, 7);
    const live_line = historyLine(6, 10, 7);

    try std.testing.expect(hist_line.hist);
    try std.testing.expectEqual(@as(i32, 5), hist_line.index);
    try std.testing.expect(!live_line.hist);
    try std.testing.expectEqual(@as(i32, 0), live_line.index);
}

test "search utf8 cursor and delete word plans" {
    const input = "abc  你好";

    try std.testing.expectEqual(@as(usize, 5), deleteWordStart(input, input.len));
    try std.testing.expectEqual(@as(usize, 8), prevChar(input, input.len));
    try std.testing.expectEqual(@as(usize, 8), nextChar(input, 5));
}

test "search input edit plans guard inactive states" {
    try std.testing.expect(!insertPlan(false, 3, 1, 8, 2).run);
    try std.testing.expect(insertPlan(true, 0, 0, 8, 2).run);
    try std.testing.expectEqual(CursorEdit.none, cursorEdit("abc", true, 3, 0, .backspace));
    try std.testing.expectEqual(CursorEdit.none, cursorEdit("abc", true, 3, 3, .delete_forward));
    try std.testing.expectEqual(CursorEdit.none, cursorEdit("abc", true, 3, 0, .delete_word));
    try std.testing.expectEqual(@as(usize, 0), cursorEdit("abc", true, 3, 2, .home).move);
    try std.testing.expect(scanPlan(true, 2));
}

test "search insert plan computes buffer movement and growth" {
    const inactive = insertPlan(false, 3, 1, 8, 2);
    const empty = insertPlan(true, 0, 0, 8, 2);
    const in_place = insertPlan(true, 3, 1, 8, 2);
    const grow = insertPlan(true, 7, 3, 8, 2);

    try std.testing.expect(!inactive.run);
    try std.testing.expect(empty.run);
    try std.testing.expectEqual(@as(usize, 2), empty.new_len);
    try std.testing.expectEqual(@as(usize, 2), empty.new_cursor);
    try std.testing.expect(in_place.run);
    try std.testing.expect(!in_place.grow);
    try std.testing.expectEqual(@as(usize, 1), in_place.insert_at);
    try std.testing.expectEqual(@as(usize, 3), in_place.move_dst);
    try std.testing.expectEqual(@as(usize, 1), in_place.move_src);
    try std.testing.expectEqual(@as(usize, 3), in_place.move_len);
    try std.testing.expectEqual(@as(usize, 5), in_place.new_len);
    try std.testing.expectEqual(@as(usize, 3), in_place.new_cursor);
    try std.testing.expect(grow.grow);
    try std.testing.expectEqual(@as(usize, 16), grow.inputcap);
}

test "search cursor edit union covers delete and movement actions" {
    const input = "abc  你好";
    const backspace = cursorEdit(input, true, input.len, input.len, .backspace);
    const delete_forward = cursorEdit(input, true, input.len, 5, .delete_forward);
    const delete_word = cursorEdit(input, true, input.len, input.len, .delete_word);
    const move_left = cursorEdit(input, true, input.len, input.len, .move_left);
    const move_right = cursorEdit(input, true, input.len, 5, .move_right);
    const home_edit = cursorEdit(input, true, input.len, input.len, .home);
    const end_edit = cursorEdit(input, true, input.len, 0, .end);
    const inactive = cursorEdit(input, false, input.len, input.len, .backspace);

    try std.testing.expectEqual(@as(usize, 8), backspace.delete.start);
    try std.testing.expectEqual(@as(usize, input.len), backspace.delete.end);
    try std.testing.expectEqual(@as(usize, 8), backspace.delete.cursor);
    try std.testing.expectEqual(@as(usize, 5), delete_forward.delete.start);
    try std.testing.expectEqual(@as(usize, 8), delete_forward.delete.end);
    try std.testing.expectEqual(@as(usize, 5), delete_word.delete.start);
    try std.testing.expectEqual(@as(usize, 8), move_left.move);
    try std.testing.expectEqual(@as(usize, 8), move_right.move);
    try std.testing.expectEqual(@as(usize, 0), home_edit.move);
    try std.testing.expectEqual(@as(usize, input.len), end_edit.move);
    try std.testing.expectEqual(CursorEdit.none, inactive);
}

test "search state edit union covers clear commit and cancel" {
    const inactive_clear = clearInputEdit(false);
    const clear = clearInputEdit(true);
    const inactive_commit = commitEdit(false, 3);
    const commit_clear = commitEdit(true, 0);
    const commit_set = commitEdit(true, 3);
    const cancel = cancelEdit(true);

    try std.testing.expectEqual(StateEdit.none, inactive_clear);
    try std.testing.expectEqual(@as(usize, 0), clear.clear_input.len);
    try std.testing.expectEqual(@as(usize, 0), clear.clear_input.cursor);
    try std.testing.expectEqual(StateEdit.none, inactive_commit);
    try std.testing.expectEqual(StateEdit.commit_clear, commit_clear);
    try std.testing.expectEqual(StateEdit.commit_set, commit_set);
    try std.testing.expectEqual(StateEdit.cancel, cancel);
}

test "search commit prompt and match capacity plans" {
    try std.testing.expect(deletePlan(2, 5, 9).run);
    try std.testing.expectEqual(@as(usize, 6), deletePlan(2, 5, 9).new_len);
    try std.testing.expect(!deletePlan(5, 2, 9).run);
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

    const prompt = promptResult(.{
        .query_len = 0,
        .inputmode = false,
        .inputlen = 4,
        .inputcursor = 2,
        .inputcap = 0,
        .nmatches = 3,
        .match_cap = 8,
        .current = 1,
        .active = true,
    });
    try std.testing.expect(prompt.update.inputmode);
    try std.testing.expectEqual(@as(usize, 0), prompt.update.inputlen);
    try std.testing.expectEqual(@as(usize, 0), prompt.update.inputcursor);
    try std.testing.expectEqual(@as(usize, 64), prompt.update.inputcap);
    try std.testing.expectEqual(@as(i32, 1), prompt.update.current);
    try std.testing.expect(prompt.update.active);
    try std.testing.expect(prompt.effect.alloc_input);
    try std.testing.expect(prompt.effect.redraw);

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
