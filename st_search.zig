//! search 领域状态机，不直接暴露 C ABI。
//! [输入]: 搜索输入状态、匹配数量、当前索引、UTF-8 字节序列。
//! [输出]: 搜索栏编辑、跳转、提交/取消的内部决策结果。
//! [定位]: 承载 search 相关纯逻辑，C adapter 只负责转换 extern struct。

const std = @import("std");
const line_core = @import("st_line_core.zig");
const model = @import("term_model.zig");

pub const ZigGlyph = extern struct {
    u: u32,
    mode: c_ushort,
    fg: u32,
    bg: u32,
};

pub const ZigSearchStepPlan = extern struct {
    run: c_int,
    current: c_int,
};

pub const ZigSearchJumpPlan = extern struct {
    run: c_int,
    new_scr: c_int,
};

pub const ZigSearchDeletePlan = extern struct {
    run: c_int,
    new_len: usize,
};

pub const ZigSearchLinePlan = extern struct {
    kind: c_int,
    cap: c_int,
    next_x: c_int,
    match: SearchMatch,
};

pub const ZigSearchSnapshot = extern struct {
    query_len: c_int,
    inputmode: c_int,
    inputlen: usize,
    inputcursor: usize,
    inputcap: usize,
    nmatches: c_int,
    match_cap: c_int,
    current: c_int,
    active: c_int,
};

pub const ZigSearchStateUpdate = extern struct {
    query_len: c_int,
    active: c_int,
    current: c_int,
    inputmode: c_int,
    inputlen: usize,
    inputcursor: usize,
    inputcap: usize,
    nmatches: c_int,
    match_cap: c_int,
};

pub const ZigSearchEffectPlan = extern struct {
    alloc_input: c_int,
    realloc_input: c_int,
    alloc_query: c_int,
    realloc_matches: c_int,
    reuse_matches: c_int,
    clear_query: c_int,
    clear_matches: c_int,
    refresh_search: c_int,
    redraw: c_int,
    jump: c_int,
};

pub const ZigSearchPromptResult = extern struct {
    update: ZigSearchStateUpdate,
    effect: ZigSearchEffectPlan,
};

pub const ZigSearchInputResult = extern struct {
    update: ZigSearchStateUpdate,
    effect: ZigSearchEffectPlan,
    insert_at: usize,
    move_dst: usize,
    move_src: usize,
    move_len: usize,
};

pub const ZigSearchCursorResult = extern struct {
    update: ZigSearchStateUpdate,
    effect: ZigSearchEffectPlan,
    delete_start: usize,
    delete_end: usize,
};

pub const ZigSearchStateResult = extern struct {
    update: ZigSearchStateUpdate,
    effect: ZigSearchEffectPlan,
};

pub const ZigSearchScanResult = extern struct {
    update: ZigSearchStateUpdate,
    effect: ZigSearchEffectPlan,
};

pub const ZigSearchSetResult = extern struct {
    update: ZigSearchStateUpdate,
    effect: ZigSearchEffectPlan,
    alloc_len: usize,
};

fn boolInt(value: bool) c_int {
    return if (value) 1 else 0;
}

// step 只服务“下一条/上一条匹配”这种循环跳转，不携带任何副作用。
pub const StepPlan = struct {
    run: bool,
    current: i32,
};

// delete 只回答“这次删不删、删完长度是多少”，真正的 memmove 留给 C。
pub const DeletePlan = struct {
    run: bool,
    new_len: usize,
};

// insert 描述一次插入对 buffer 视图的影响。
// 这里故意把 move 段信息也算出来，这样 C shim 不需要重复推导位移范围。
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

pub const CursorAction = enum(i32) {
    backspace = 1,
    delete_forward = 2,
    delete_word = 3,
    move_left = 4,
    move_right = 5,
    home = 6,
    end = 7,
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

pub const StateAction = enum(i32) {
    clear_input = 1,
    commit = 2,
    cancel = 3,
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
    // 第一版状态快照只携带可直接复制的标量，buffer 本体仍由 C 持有。
    // 这样 Zig 可以一次拿到“当前 search 视图”，而不必通过很多小 helper 反复回读 C 状态。
    // 原始 UTF-8 字节长度，主要用于决定 query buffer 分配规模。
    query_len: i32,
    // 搜索是否处于输入/激活态，决定 prompt/input/set 分支如何走。
    inputmode: bool,
    // 输入缓冲区已写入的字节数，不包含结尾 '\0'。
    inputlen: usize,
    // 当前输入光标位置，始终指向 UTF-8 codepoint 边界。
    inputcursor: usize,
    // 输入 buffer 的容量，C 侧会按 effect 决定是否 realloc。
    inputcap: usize,
    // 当前已扫描到的匹配总数，用于 current/jump 的归一化。
    nmatches: i32,
    // matches 数组当前容量，避免 Zig/C 两边各自重复推导。
    match_cap: i32,
    // 当前高亮匹配索引；-1 表示没有稳定 current。
    current: i32,
    // 当前 search 是否激活；inactive 时所有编辑/扫描动作都应短路。
    active: bool,
};

pub const SearchStateUpdate = struct {
    // Zig 负责算出下一状态，C 只按结果写回，不再分散修补字段。
    // 这里保留 query_len，是为了让 searchset 这类入口也能把 decoded qlen 一并写回。
    // decoded 后的 Rune 数量；和 snapshot.query_len 的 UTF-8 字节长度不同。
    query_len: i32,
    // 最终激活态，写回 search.active。
    active: bool,
    // 归一化后的 current 索引，供跳转和后续扫描收尾使用。
    current: i32,
    // 输入栏是否仍处在编辑态。
    inputmode: bool,
    // 输入缓冲区最终字节长度，不含 '\0'。
    inputlen: usize,
    // 输入光标最终位置。
    inputcursor: usize,
    // 输入 buffer 最终容量。
    inputcap: usize,
    // 最终匹配数量，允许 C 直接写回 search.nmatches。
    nmatches: i32,
    // 最终匹配数组容量，供后续 append/realloc 继续沿用。
    match_cap: i32,
};

pub const SearchEffectPlan = struct {
    // effect 只描述需要触发的副作用，不直接持有任何平台资源。
    // 目标是把“做什么”与“怎么做”拆开：Zig 决定动作，C 执行平台相关细节。
    // 首次 prompt 时需要分配输入 buffer。
    alloc_input: bool,
    // 输入编辑导致 buffer 需要重分配。
    realloc_input: bool,
    // 需要分配 query Rune buffer。
    alloc_query: bool,
    // 需要重分配 matches 数组。
    realloc_matches: bool,
    // 需要把 matches 缓冲区视为可复用，但不立即释放。
    reuse_matches: bool,
    // C 需要释放旧 query buffer。
    clear_query: bool,
    // C 需要清理旧 matches。
    clear_matches: bool,
    // 需要重新扫描行/历史。
    refresh_search: bool,
    // 需要 redraw 一次。
    redraw: bool,
    // 需要把 current 跳到对应 scrollback 层。
    jump: bool,
};

pub const SearchPromptResult = struct {
    // prompt 入口不碰文本内容，只重置输入视图并声明是否要分配输入缓冲区。
    update: SearchStateUpdate,
    effect: SearchEffectPlan,
};

pub const SearchInputResult = struct {
    update: SearchStateUpdate,
    effect: SearchEffectPlan,
    // 输入插入仍由 C 执行 memmove/memcpy，所以保留最小位移信息。
    // 新字符的插入位置。
    insert_at: usize,
    // 旧内容整体后移的目标位置。
    move_dst: usize,
    // 旧内容整体后移的源位置。
    move_src: usize,
    // 后移字节长度，包含尾随 '\0'。
    move_len: usize,
};

pub const SearchCursorResult = struct {
    update: SearchStateUpdate,
    effect: SearchEffectPlan,
    delete_start: usize,
    delete_end: usize,
};

pub const SearchStateResult = struct {
    update: SearchStateUpdate,
    effect: SearchEffectPlan,
};

pub const SearchScanResult = struct {
    update: SearchStateUpdate,
    effect: SearchEffectPlan,
};

pub const SearchSetResult = struct {
    // set 入口比较特殊：它先需要 alloc_len 让 C 做 UTF-8 decode，
    // decode 完毕后再根据真实 qlen 生成最终状态与 effect。
    update: SearchStateUpdate,
    effect: SearchEffectPlan,
    // decode 前的 query Rune buffer 预估长度，至少为 1。
    alloc_len: usize,
};

pub const SearchModel = struct {
    state: SearchSnapshot,

    pub fn init(state: SearchSnapshot) SearchModel {
        return .{ .state = state };
    }

    pub fn prompt(self: SearchModel) SearchPromptResult {
        return promptResult(self.state);
    }

    pub fn input(self: SearchModel, add_len: usize) SearchInputResult {
        return inputResult(self.state, add_len);
    }

    pub fn cursor(self: SearchModel, input_bytes: []const u8, action: CursorAction) SearchCursorResult {
        return cursorResult(self.state, input_bytes, action);
    }

    pub fn stateAction(self: SearchModel, action: StateAction) SearchStateResult {
        return stateResult(self.state, action);
    }

    pub fn scan(self: SearchModel, nmatches: i32, current: i32) SearchScanResult {
        return scanResult(self.state, nmatches, current);
    }

    pub fn set(self: SearchModel, query_len: usize, qlen: i32) SearchSetResult {
        return setResult(self.state, query_len, qlen);
    }
};

pub const SetPlan = struct {
    // query Rune buffer 的最终分配长度。
    alloc_len: usize,
    // qlen > 0 时 search 才进入 active。
    active: bool,
    // 重新设置 query 后 current 回退到 -1，等待 C 后续归一化。
    current: i32,
};

pub const JumpPlan = struct {
    run: bool,
    new_scr: i32,
};

pub const Hit = struct {
    // search 是否激活；inactive 时命中永远为 false。
    active: bool,
    // 命中的匹配所在 scrollback 层。
    match_scr: i32,
    // 当前终端所在 scrollback 层。
    term_scr: i32,
    // 命中的行号。
    match_y: i32,
    // 查询点所在行号。
    y: i32,
    // 查询点所在列号。
    x: i32,
    // 匹配起始列号。
    match_x: i32,
    // 匹配长度，单位是 glyph，不是字节。
    match_len: i32,

    pub fn contains(self: Hit) bool {
        return self.active and self.match_scr == self.term_scr and self.match_y == self.y and between(self.x, self.match_x, self.match_x + self.match_len - 1);
    }
};

pub const SearchMatch = extern struct {
    // 命中位置列号。
    x: i32,
    // 命中位置行号。
    y: i32,
    // 命中所在的 scrollback 层。
    scr: i32,
    // 匹配长度。
    len: i32,

    pub fn hit(self: SearchMatch, active: bool, term_scr: i32, x: i32, y: i32) bool {
        return (Hit{ .active = active, .match_scr = self.scr, .term_scr = term_scr, .match_y = self.y, .y = y, .x = x, .match_x = self.x, .match_len = self.len }).contains();
    }
};

pub const ScanLine = struct {
    // 当前扫描行的有效长度。
    linelen: i32,
    // 查询 Rune 数量。
    query_len: i32,

    pub fn lastStart(self: ScanLine) i32 {
        return self.linelen - self.query_len;
    }
};

pub const MatchAppendKind = enum(i32) {
    // 当前 x 位置没有命中，继续扫描。
    skip = 0,
    // 可以直接追加当前匹配。
    append = 1,
    // 需要先扩容再追加。
    grow_append = 2,
};

pub const GrowAppend = struct {
    // 扩容后的新容量。
    cap: i32,
    // 需要追加的匹配本体。
    match: SearchMatch,
};

pub const MatchAppend = union(MatchAppendKind) {
    // 当前 x 没有命中。
    skip,
    // 直接追加一条匹配。
    append: SearchMatch,
    // 需要扩容后再追加。
    grow_append: GrowAppend,
};

pub const MatchList = struct {
    // 扫描得到的全部匹配列表。
    matches: []const SearchMatch,
    // search 是否激活。
    active: bool,
    // current 高亮索引。
    current: i32,

    pub fn contains(self: MatchList, term_scr: i32, x: i32, y: i32) bool {
        // 普通高亮只关心“任意匹配是否覆盖当前位置”，不区分 current。
        for (self.matches) |match| {
            if (match.hit(self.active, term_scr, x, y)) return true;
        }
        return false;
    }

    pub fn containsCurrent(self: MatchList, term_scr: i32, x: i32, y: i32) bool {
        // current 高亮必须先确认 current 仍落在合法匹配范围里，
        // 这样历史匹配数量变化后不会读到失效索引。
        if (!(Matches{ .active = self.active, .current = self.current, .count = @intCast(self.matches.len) }).currentValid()) return false;
        return self.matches[@intCast(self.current)].hit(self.active, term_scr, x, y);
    }
};

pub const Matches = struct {
    // search 是否激活。
    active: bool,
    // 当前高亮索引。
    current: i32,
    // 当前匹配总数。
    count: i32,

    pub fn currentValid(self: Matches) bool {
        return self.active and self.current >= 0 and self.current < self.count;
    }

    pub fn nextCurrent(self: Matches) i32 {
        // 没有任何匹配时返回 -1；旧 current 仍合法就保留，
        // 否则回退到第 0 个匹配，保证 search.current 总能落到稳定值上。
        if (self.count == 0) return -1;
        if (between(self.current, 0, self.count - 1)) return self.current;
        return 0;
    }

    pub fn step(self: Matches, direction: i32) StepPlan {
        // next/prev 逻辑在匹配集合内部循环，不让 current 越出 [0, count)。
        if (!self.active or self.count == 0) return .{ .run = false, .current = self.current };
        return .{
            .run = true,
            .current = @mod(self.current + self.count + direction, self.count),
        };
    }

    pub fn nextCap(self: Matches, cap: i32) i32 {
        // 匹配数组采用指数扩容，避免 scan 时频繁 realloc。
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
    // current 是否有效；无效时不允许切换 scrollback 层。
    current_valid: bool,
    // 终端当前所在 scrollback 层。
    term_scr: i32,
    // 目标匹配所在 scrollback 层。
    match_scr: i32,

    pub fn scroll(self: Jump) i32 {
        if (!self.current_valid) return self.term_scr;
        return if (self.term_scr != self.match_scr) self.match_scr else self.term_scr;
    }
};

pub const History = struct {
    // 环形历史缓冲的头指针。
    head: i32,
    // 环形历史缓冲大小。
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
    // 历史总容量。
    histsize: i32,
    // 当前终端行数，用于区分历史区和可见区。
    rows: i32,

    pub fn line(self: HistoryView, y: i32) HistoryLine {
        const last_hist = self.histsize - self.rows + 2;
        if (y <= last_hist) return .{ .hist = true, .index = y };
        return .{ .hist = false, .index = y - self.histsize + self.rows - 3 };
    }
};

pub const Input = struct {
    // search 输入是否可编辑。
    active: bool,
    // 当前输入长度，不含 '\0'。
    len: usize,
    // 当前光标位置。
    cursor: usize,
    // 当前 buffer 容量。
    cap: usize,

    pub fn nextCap(self: Input, add_len: usize) usize {
        // 输入缓冲区沿用倍增扩容策略，保证追加和中间插入都能摊薄 realloc 成本。
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
        // InsertPlan 把“插入文本后哪些字节要后移”一次算清，
        // C 侧只需要按 move_src/move_dst/move_len 执行内存移动即可。
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
    // 原始输入字节视图，光标移动要按 UTF-8 codepoint 边界处理。
    bytes: []const u8,

    pub fn prevChar(self: InputBytes, cursor: usize) usize {
        // search 输入框按 UTF-8 codepoint 移动，
        // 这里通过跳过 continuation byte 保证不会把光标停在多字节字符中间。
        if (cursor == 0) return 0;
        var next = cursor - 1;
        while (next > 0 and (self.bytes[next] & 0xc0) == 0x80) {
            next -= 1;
        }
        return next;
    }

    pub fn nextChar(self: InputBytes, cursor: usize) usize {
        // 与 prevChar 对称：从下一个字节开始跳过 continuation byte，
        // 最终停在下一个字符边界或输入末尾。
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
    // 当前输入状态快照。
    input: Input,
    // 原始字节视图，用于计算 UTF-8 边界。
    bytes: InputBytes,

    pub fn backspace(self: InputEditor) CursorEdit {
        // 编辑器层把“是否允许操作”和“光标边界如何移动”封装起来，
        // C 不需要理解 UTF-8 或删除范围细节，只消费结果即可。
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
        // 当前扫描行的 glyph 切片。
        line: []const Glyph,
        // 这行的有效长度。
        linelen: i32,
        // 可见列数。
        cols: i32,

        const Self = @This();

        pub fn match(self: Self, x: i32, query: []const u32) i32 {
            // 行级匹配需要跳过 wide dummy cell，
            // 否则双宽字符的占位格会把 query 对齐和 match_len 算错。
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

pub fn jumpPlan(active: bool, current: i32, nmatches: i32, term_scr: i32, match_scr: i32) JumpPlan {
    const valid = currentValid(active, current, nmatches);
    return .{
        .run = valid,
        .new_scr = if (valid) jumpScroll(valid, term_scr, match_scr) else term_scr,
    };
}

pub fn scanResult(snapshot: SearchSnapshot, nmatches: i32, current: i32) SearchScanResult {
    const next_current = nextCurrent(current, nmatches);
    return .{
        .update = .{
            .query_len = snapshot.query_len,
            .active = snapshot.active,
            .current = next_current,
            .inputmode = snapshot.inputmode,
            .inputlen = snapshot.inputlen,
            .inputcursor = snapshot.inputcursor,
            .inputcap = snapshot.inputcap,
            .nmatches = nmatches,
            .match_cap = snapshot.match_cap,
        },
        .effect = .{
            .alloc_input = false,
            .realloc_input = false,
            .alloc_query = false,
            .realloc_matches = false,
            .reuse_matches = true,
            .clear_query = false,
            .clear_matches = false,
            .refresh_search = false,
            .redraw = false,
            .jump = false,
        },
    };
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
    // prompt 入口先重置输入视图，再把真正的分配/redraw 留给 C shim。
    const plan = promptPlan(snapshot.inputcap != 0, snapshot.inputcap);
    return .{
        .update = .{
            .query_len = snapshot.query_len,
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
            .reuse_matches = false,
            .clear_query = false,
            .clear_matches = false,
            .refresh_search = false,
            .redraw = true,
            .jump = false,
        },
    };
}

pub fn cursorResult(snapshot: SearchSnapshot, input: []const u8, action: CursorAction) SearchCursorResult {
    const edit = switch (action) {
        .backspace => cursorEdit(input, snapshot.inputmode, snapshot.inputlen, snapshot.inputcursor, .backspace),
        .delete_forward => cursorEdit(input, snapshot.inputmode, snapshot.inputlen, snapshot.inputcursor, .delete_forward),
        .delete_word => cursorEdit(input, snapshot.inputmode, snapshot.inputlen, snapshot.inputcursor, .delete_word),
        .move_left => cursorEdit(input, snapshot.inputmode, snapshot.inputlen, snapshot.inputcursor, .move_left),
        .move_right => cursorEdit(input, snapshot.inputmode, snapshot.inputlen, snapshot.inputcursor, .move_right),
        .home => cursorEdit(&.{}, snapshot.inputmode, snapshot.inputlen, 0, .home),
        .end => cursorEdit(&.{}, snapshot.inputmode, snapshot.inputlen, snapshot.inputlen, .end),
    };

    return switch (edit) {
        .none => .{
            .update = .{
                .query_len = snapshot.query_len,
                .active = snapshot.active,
                .current = snapshot.current,
                .inputmode = snapshot.inputmode,
                .inputlen = snapshot.inputlen,
                .inputcursor = snapshot.inputcursor,
                .inputcap = snapshot.inputcap,
                .nmatches = snapshot.nmatches,
                .match_cap = snapshot.match_cap,
            },
            .effect = .{
                .alloc_input = false,
                .realloc_input = false,
                .alloc_query = false,
                .realloc_matches = false,
                .reuse_matches = false,
                .clear_query = false,
                .clear_matches = false,
                .refresh_search = false,
                .redraw = false,
                .jump = false,
            },
            .delete_start = 0,
            .delete_end = 0,
        },
        .delete => |delete| .{
            .update = .{
                .query_len = snapshot.query_len,
                .active = snapshot.active,
                .current = snapshot.current,
                .inputmode = snapshot.inputmode,
                .inputlen = snapshot.inputlen - (delete.end - delete.start),
                .inputcursor = delete.cursor,
                .inputcap = snapshot.inputcap,
                .nmatches = snapshot.nmatches,
                .match_cap = snapshot.match_cap,
            },
            .effect = .{
                .alloc_input = false,
                .realloc_input = false,
                .alloc_query = false,
                .realloc_matches = false,
                .reuse_matches = false,
                .clear_query = false,
                .clear_matches = false,
                .refresh_search = true,
                .redraw = false,
                .jump = false,
            },
            .delete_start = delete.start,
            .delete_end = delete.end,
        },
        .move => |cursor| .{
            .update = .{
                .query_len = snapshot.query_len,
                .active = snapshot.active,
                .current = snapshot.current,
                .inputmode = snapshot.inputmode,
                .inputlen = snapshot.inputlen,
                .inputcursor = cursor,
                .inputcap = snapshot.inputcap,
                .nmatches = snapshot.nmatches,
                .match_cap = snapshot.match_cap,
            },
            .effect = .{
                .alloc_input = false,
                .realloc_input = false,
                .alloc_query = false,
                .realloc_matches = false,
                .reuse_matches = false,
                .clear_query = false,
                .clear_matches = false,
                .refresh_search = false,
                .redraw = true,
                .jump = false,
            },
            .delete_start = 0,
            .delete_end = 0,
        },
    };
}

pub fn inputResult(snapshot: SearchSnapshot, add_len: usize) SearchInputResult {
    // input 入口先复用既有插入规则，再把 buffer 位移细节交回 C 执行。
    const plan = insertPlan(snapshot.inputmode, snapshot.inputlen, snapshot.inputcursor, snapshot.inputcap, add_len);
    return .{
        .update = .{
            .query_len = snapshot.query_len,
            .active = snapshot.active,
            .current = snapshot.current,
            .inputmode = snapshot.inputmode,
            .inputlen = plan.new_len,
            .inputcursor = plan.new_cursor,
            .inputcap = plan.inputcap,
            .nmatches = snapshot.nmatches,
            .match_cap = snapshot.match_cap,
        },
        .effect = .{
            .alloc_input = false,
            .realloc_input = plan.grow,
            .alloc_query = false,
            .realloc_matches = false,
            .reuse_matches = false,
            .clear_query = false,
            .clear_matches = false,
            .refresh_search = plan.run,
            .redraw = false,
            .jump = false,
        },
        .insert_at = plan.insert_at,
        .move_dst = plan.move_dst,
        .move_src = plan.move_src,
        .move_len = plan.move_len,
    };
}

pub fn stateResult(snapshot: SearchSnapshot, action: StateAction) SearchStateResult {
    const edit = switch (action) {
        .clear_input => clearInputEdit(snapshot.inputmode),
        .commit => commitEdit(snapshot.inputmode, snapshot.inputlen),
        .cancel => cancelEdit(snapshot.inputmode),
    };

    return switch (edit) {
        .none => .{
            .update = .{
                .query_len = snapshot.query_len,
                .active = snapshot.active,
                .current = snapshot.current,
                .inputmode = snapshot.inputmode,
                .inputlen = snapshot.inputlen,
                .inputcursor = snapshot.inputcursor,
                .inputcap = snapshot.inputcap,
                .nmatches = snapshot.nmatches,
                .match_cap = snapshot.match_cap,
            },
            .effect = .{
                .alloc_input = false,
                .realloc_input = false,
                .alloc_query = false,
                .realloc_matches = false,
                .reuse_matches = false,
                .clear_query = false,
                .clear_matches = false,
                .refresh_search = false,
                .redraw = false,
                .jump = false,
            },
        },
        .clear_input => |clear| .{
            .update = .{
                .query_len = snapshot.query_len,
                .active = snapshot.active,
                .current = snapshot.current,
                .inputmode = snapshot.inputmode,
                .inputlen = clear.len,
                .inputcursor = clear.cursor,
                .inputcap = snapshot.inputcap,
                .nmatches = snapshot.nmatches,
                .match_cap = snapshot.match_cap,
            },
            .effect = .{
                .alloc_input = false,
                .realloc_input = false,
                .alloc_query = false,
                .realloc_matches = false,
                .reuse_matches = false,
                .clear_query = false,
                .clear_matches = false,
                .refresh_search = true,
                .redraw = false,
                .jump = false,
            },
        },
        .commit_clear => .{
            .update = .{
                .query_len = 0,
                .active = false,
                .current = -1,
                .inputmode = false,
                .inputlen = 0,
                .inputcursor = 0,
                .inputcap = 0,
                .nmatches = 0,
                .match_cap = 0,
            },
            .effect = .{
                .alloc_input = false,
                .realloc_input = false,
                .alloc_query = false,
                .realloc_matches = false,
                .reuse_matches = false,
                .clear_query = true,
                .clear_matches = true,
                .refresh_search = false,
                .redraw = true,
                .jump = false,
            },
        },
        .commit_set => .{
            .update = .{
                .query_len = snapshot.query_len,
                .active = snapshot.active,
                .current = snapshot.current,
                .inputmode = false,
                .inputlen = snapshot.inputlen,
                .inputcursor = snapshot.inputcursor,
                .inputcap = snapshot.inputcap,
                .nmatches = snapshot.nmatches,
                .match_cap = snapshot.match_cap,
            },
            .effect = .{
                .alloc_input = false,
                .realloc_input = false,
                .alloc_query = false,
                .realloc_matches = false,
                .reuse_matches = false,
                .clear_query = false,
                .clear_matches = false,
                .refresh_search = true,
                .redraw = false,
                .jump = false,
            },
        },
        .cancel => .{
            .update = .{
                .query_len = snapshot.query_len,
                .active = snapshot.active,
                .current = snapshot.current,
                .inputmode = false,
                .inputlen = snapshot.inputlen,
                .inputcursor = snapshot.inputcursor,
                .inputcap = snapshot.inputcap,
                .nmatches = snapshot.nmatches,
                .match_cap = snapshot.match_cap,
            },
            .effect = .{
                .alloc_input = false,
                .realloc_input = false,
                .alloc_query = false,
                .realloc_matches = false,
                .reuse_matches = false,
                .clear_query = false,
                .clear_matches = false,
                .refresh_search = false,
                .redraw = true,
                .jump = false,
            },
        },
    };
}

pub fn setResult(snapshot: SearchSnapshot, query_len: usize, qlen: i32) SearchSetResult {
    // set 入口是 search 状态切换的关口：Zig 只决定新状态和 effect，UTF-8 decode/scan/jump 仍由 C 驱动。
    // 这里的 query_len 是原始 UTF-8 字节长度，qlen 是 decode 后的 Rune 数量；
    // 两者都保留是为了把“分配多大 buffer”和“搜索是否 active”分开计算。
    const plan = setPlan(query_len, qlen);
    return .{
        .update = .{
            .query_len = qlen,
            .active = plan.active,
            .current = plan.current,
            .inputmode = snapshot.inputmode,
            .inputlen = snapshot.inputlen,
            .inputcursor = snapshot.inputcursor,
            .inputcap = snapshot.inputcap,
            .nmatches = snapshot.nmatches,
            .match_cap = snapshot.match_cap,
        },
        .effect = .{
            .alloc_input = false,
            .realloc_input = false,
            .alloc_query = true,
            .realloc_matches = false,
            .reuse_matches = false,
            .clear_query = true,
            .clear_matches = false,
            .refresh_search = true,
            .redraw = true,
            .jump = true,
        },
        .alloc_len = plan.alloc_len,
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

pub fn zigSnapshot(snapshot: ZigSearchSnapshot) SearchSnapshot {
    return .{
        .query_len = snapshot.query_len,
        .inputmode = snapshot.inputmode != 0,
        .inputlen = snapshot.inputlen,
        .inputcursor = snapshot.inputcursor,
        .inputcap = snapshot.inputcap,
        .nmatches = snapshot.nmatches,
        .match_cap = snapshot.match_cap,
        .current = snapshot.current,
        .active = snapshot.active != 0,
    };
}

pub fn zigStateUpdate(update: SearchStateUpdate) ZigSearchStateUpdate {
    return .{
        .query_len = update.query_len,
        .active = boolInt(update.active),
        .current = update.current,
        .inputmode = boolInt(update.inputmode),
        .inputlen = update.inputlen,
        .inputcursor = update.inputcursor,
        .inputcap = update.inputcap,
        .nmatches = update.nmatches,
        .match_cap = update.match_cap,
    };
}

pub fn zigEffectPlan(effect: SearchEffectPlan) ZigSearchEffectPlan {
    return .{
        .alloc_input = boolInt(effect.alloc_input),
        .realloc_input = boolInt(effect.realloc_input),
        .alloc_query = boolInt(effect.alloc_query),
        .realloc_matches = boolInt(effect.realloc_matches),
        .reuse_matches = boolInt(effect.reuse_matches),
        .clear_query = boolInt(effect.clear_query),
        .clear_matches = boolInt(effect.clear_matches),
        .refresh_search = boolInt(effect.refresh_search),
        .redraw = boolInt(effect.redraw),
        .jump = boolInt(effect.jump),
    };
}

pub fn zigSearchmatchlist(matches: ?[*]const SearchMatch, nmatches: c_int, active: c_int, current: c_int, term_scr: c_int, x: c_int, y: c_int) c_int {
    const count: usize = if (nmatches > 0) @intCast(nmatches) else 0;
    const items = if (count == 0) &[_]SearchMatch{} else (matches orelse return 0)[0..count];
    return boolInt(matchListContains(items, active != 0, current, term_scr, x, y));
}

pub fn zigSearchcurrentmatch(matches: ?[*]const SearchMatch, nmatches: c_int, active: c_int, current: c_int, term_scr: c_int, x: c_int, y: c_int) c_int {
    const count: usize = if (nmatches > 0) @intCast(nmatches) else 0;
    const items = if (count == 0) &[_]SearchMatch{} else (matches orelse return 0)[0..count];
    return boolInt(matchListCurrent(items, active != 0, current, term_scr, x, y));
}

pub fn zigSearchlineplan(line: [*]const ZigGlyph, start_x: c_int, col: c_int, query: [*]const u32, qlen: c_int, nmatches: c_int, cap: c_int, y: c_int, scr: c_int) ZigSearchLinePlan {
    const glyphs = line[0..@intCast(col)];
    const linelen = (line_core.Line(ZigGlyph){ .glyphs = glyphs, .cols = col }).length();
    const last_x = scanLineLastStart(linelen, qlen);
    var x = start_x;
    while (x <= last_x) : (x += 1) {
        const match_len = lineMatch(ZigGlyph, glyphs, x, linelen, query[0..@intCast(qlen)], col);
        const plan = appendMatch(match_len, nmatches, cap, x, y, scr);
        switch (plan) {
            .skip => {},
            .append => |match| return .{ .kind = @intFromEnum(MatchAppendKind.append), .cap = cap, .next_x = x + 1, .match = match },
            .grow_append => |grow| return .{ .kind = @intFromEnum(MatchAppendKind.grow_append), .cap = grow.cap, .next_x = x + 1, .match = grow.match },
        }
    }
    return .{ .kind = @intFromEnum(MatchAppendKind.skip), .cap = cap, .next_x = x, .match = .{ .x = 0, .y = 0, .scr = 0, .len = 0 } };
}

export fn st_searchmatchlist(matches: ?[*]const SearchMatch, nmatches: c_int, active: c_int, current: c_int, term_scr: c_int, x: c_int, y: c_int) c_int {
    return zigSearchmatchlist(matches, nmatches, active, current, term_scr, x, y);
}

export fn st_searchcurrentmatch(matches: ?[*]const SearchMatch, nmatches: c_int, active: c_int, current: c_int, term_scr: c_int, x: c_int, y: c_int) c_int {
    return zigSearchcurrentmatch(matches, nmatches, active, current, term_scr, x, y);
}

export fn st_searchlineplan(line: [*]const ZigGlyph, start_x: c_int, col: c_int, query: [*]const u32, qlen: c_int, nmatches: c_int, cap: c_int, y: c_int, scr: c_int) ZigSearchLinePlan {
    return zigSearchlineplan(line, start_x, col, query, qlen, nmatches, cap, y, scr);
}

pub fn zigSearchstep(active: c_int, nmatches: c_int, current: c_int, direction: c_int) ZigSearchStepPlan {
    const plan = step(active != 0, nmatches, current, direction);
    return .{ .run = boolInt(plan.run), .current = plan.current };
}

export fn st_searchstep(active: c_int, nmatches: c_int, current: c_int, direction: c_int) ZigSearchStepPlan {
    return zigSearchstep(active, nmatches, current, direction);
}

pub fn zigSearchjumpplan(active: c_int, current: c_int, nmatches: c_int, term_scr: c_int, match_scr: c_int) ZigSearchJumpPlan {
    const plan = jumpPlan(active != 0, current, nmatches, term_scr, match_scr);
    return .{ .run = boolInt(plan.run), .new_scr = plan.new_scr };
}

export fn st_searchjumpplan(active: c_int, current: c_int, nmatches: c_int, term_scr: c_int, match_scr: c_int) ZigSearchJumpPlan {
    return zigSearchjumpplan(active, current, nmatches, term_scr, match_scr);
}

pub fn zigSearchcursorupdate(snapshot: ZigSearchSnapshot, input: [*]const u8, action: c_int) ZigSearchCursorResult {
    const result = SearchModel.init(zigSnapshot(snapshot)).cursor(input[0..snapshot.inputlen], @enumFromInt(action));
    return .{ .update = zigStateUpdate(result.update), .effect = zigEffectPlan(result.effect), .delete_start = result.delete_start, .delete_end = result.delete_end };
}

export fn st_searchcursorupdate(snapshot: ZigSearchSnapshot, input: [*]const u8, action: c_int) ZigSearchCursorResult {
    return zigSearchcursorupdate(snapshot, input, action);
}

pub fn zigSearchstateupdate(snapshot: ZigSearchSnapshot, action: c_int) ZigSearchStateResult {
    const result = SearchModel.init(zigSnapshot(snapshot)).stateAction(@enumFromInt(action));
    return .{ .update = zigStateUpdate(result.update), .effect = zigEffectPlan(result.effect) };
}

export fn st_searchstateupdate(snapshot: ZigSearchSnapshot, action: c_int) ZigSearchStateResult {
    return zigSearchstateupdate(snapshot, action);
}

pub fn zigSearchscanupdate(snapshot: ZigSearchSnapshot, nmatches: c_int, current: c_int) ZigSearchScanResult {
    const result = SearchModel.init(zigSnapshot(snapshot)).scan(nmatches, current);
    return .{ .update = zigStateUpdate(result.update), .effect = zigEffectPlan(result.effect) };
}

export fn st_searchscanupdate(snapshot: ZigSearchSnapshot, nmatches: c_int, current: c_int) ZigSearchScanResult {
    return zigSearchscanupdate(snapshot, nmatches, current);
}

pub fn zigSearchdeleteplan(start: usize, end: usize, inputlen: usize) ZigSearchDeletePlan {
    const plan = deletePlan(start, end, inputlen);
    return .{ .run = boolInt(plan.run), .new_len = plan.new_len };
}

export fn st_searchdeleteplan(start: usize, end: usize, inputlen: usize) ZigSearchDeletePlan {
    return zigSearchdeleteplan(start, end, inputlen);
}

pub fn zigSearchpromptupdate(snapshot: ZigSearchSnapshot) ZigSearchPromptResult {
    const result = SearchModel.init(zigSnapshot(snapshot)).prompt();
    return .{ .update = zigStateUpdate(result.update), .effect = zigEffectPlan(result.effect) };
}

export fn st_searchpromptupdate(snapshot: ZigSearchSnapshot) ZigSearchPromptResult {
    return zigSearchpromptupdate(snapshot);
}

pub fn zigSearchinputupdate(snapshot: ZigSearchSnapshot, add_len: usize) ZigSearchInputResult {
    const result = SearchModel.init(zigSnapshot(snapshot)).input(add_len);
    return .{ .update = zigStateUpdate(result.update), .effect = zigEffectPlan(result.effect), .insert_at = result.insert_at, .move_dst = result.move_dst, .move_src = result.move_src, .move_len = result.move_len };
}

export fn st_searchinputupdate(snapshot: ZigSearchSnapshot, add_len: usize) ZigSearchInputResult {
    return zigSearchinputupdate(snapshot, add_len);
}

pub fn zigSearchsetupdate(snapshot: ZigSearchSnapshot, query_len: usize, qlen: c_int) ZigSearchSetResult {
    const result = SearchModel.init(zigSnapshot(snapshot)).set(query_len, qlen);
    return .{ .update = zigStateUpdate(result.update), .effect = zigEffectPlan(result.effect), .alloc_len = result.alloc_len };
}

export fn st_searchsetupdate(snapshot: ZigSearchSnapshot, query_len: usize, qlen: c_int) ZigSearchSetResult {
    return zigSearchsetupdate(snapshot, query_len, qlen);
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

    const input = inputResult(.{
        .query_len = 0,
        .inputmode = true,
        .inputlen = 3,
        .inputcursor = 1,
        .inputcap = 8,
        .nmatches = 2,
        .match_cap = 4,
        .current = 0,
        .active = true,
    }, 2);
    try std.testing.expect(input.effect.refresh_search);
    try std.testing.expectEqual(@as(usize, 1), input.insert_at);
    try std.testing.expectEqual(@as(usize, 3), input.move_dst);
    try std.testing.expectEqual(@as(usize, 1), input.move_src);
    try std.testing.expectEqual(@as(usize, 3), input.move_len);
    try std.testing.expectEqual(@as(usize, 5), input.update.inputlen);
    try std.testing.expectEqual(@as(usize, 3), input.update.inputcursor);

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

test "search model prompt owns state transition" {
    const model_state = SearchModel.init(.{
        .query_len = 2,
        .inputmode = false,
        .inputlen = 5,
        .inputcursor = 3,
        .inputcap = 0,
        .nmatches = 4,
        .match_cap = 8,
        .current = 1,
        .active = true,
    });

    const result = model_state.prompt();

    try std.testing.expect(result.update.inputmode);
    try std.testing.expectEqual(@as(usize, 0), result.update.inputlen);
    try std.testing.expectEqual(@as(usize, 0), result.update.inputcursor);
    try std.testing.expectEqual(@as(usize, 64), result.update.inputcap);
    try std.testing.expectEqual(@as(i32, 1), result.update.current);
    try std.testing.expect(result.update.active);
    try std.testing.expect(result.effect.alloc_input);
    try std.testing.expect(result.effect.redraw);
}

test "search model input owns insertion transition" {
    const model_state = SearchModel.init(.{
        .query_len = 0,
        .inputmode = true,
        .inputlen = 3,
        .inputcursor = 1,
        .inputcap = 8,
        .nmatches = 2,
        .match_cap = 4,
        .current = 0,
        .active = true,
    });

    const result = model_state.input(2);

    try std.testing.expect(result.effect.refresh_search);
    try std.testing.expectEqual(@as(usize, 1), result.insert_at);
    try std.testing.expectEqual(@as(usize, 3), result.move_dst);
    try std.testing.expectEqual(@as(usize, 1), result.move_src);
    try std.testing.expectEqual(@as(usize, 3), result.move_len);
    try std.testing.expectEqual(@as(usize, 5), result.update.inputlen);
    try std.testing.expectEqual(@as(usize, 3), result.update.inputcursor);
}

test "search adapter exports preserve line and match behaviour" {
    const line = [_]ZigGlyph{
        .{ .u = '你', .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = 0, .mode = model.attr_wdummy, .fg = 0, .bg = 0 },
        .{ .u = '好', .mode = 0, .fg = 0, .bg = 0 },
    };
    const query = [_]u32{ '你', '好' };
    const plan = st_searchlineplan(&line, 0, line.len, &query, query.len, 0, 4, 3, 2);
    const done = st_searchlineplan(&line, plan.next_x, line.len, &query, query.len, 1, 4, 3, 2);
    const matches = [_]SearchMatch{
        .{ .x = 5, .y = 4, .scr = 2, .len = 3 },
        .{ .x = 1, .y = 0, .scr = 0, .len = 2 },
    };

    try std.testing.expectEqual(@as(c_int, @intFromEnum(MatchAppendKind.append)), plan.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.match.x);
    try std.testing.expectEqual(@as(c_int, 3), plan.match.len);
    try std.testing.expectEqual(@as(c_int, 1), plan.next_x);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(MatchAppendKind.skip)), done.kind);
    try std.testing.expectEqual(@as(c_int, 1), st_searchmatchlist(&matches, matches.len, 1, -1, 2, 7, 4));
    try std.testing.expectEqual(@as(c_int, 1), st_searchcurrentmatch(&matches, matches.len, 1, 1, 0, 2, 0));
}

test "search adapter exports preserve state transitions" {
    const input = "abc  你好";
    const active = ZigSearchSnapshot{ .query_len = 0, .inputmode = 1, .inputlen = input.len, .inputcursor = input.len, .inputcap = 32, .nmatches = 0, .match_cap = 0, .current = -1, .active = 0 };
    const moved = st_searchcursorupdate(active, input, @intFromEnum(CursorAction.move_left));
    const clear = st_searchstateupdate(.{ .query_len = 2, .inputmode = 1, .inputlen = 4, .inputcursor = 4, .inputcap = 8, .nmatches = 1, .match_cap = 2, .current = 0, .active = 1 }, @intFromEnum(StateAction.clear_input));
    const prompt = st_searchpromptupdate(.{ .query_len = 0, .inputmode = 0, .inputlen = 4, .inputcursor = 2, .inputcap = 0, .nmatches = 3, .match_cap = 8, .current = 1, .active = 1 });
    const set = st_searchsetupdate(.{ .query_len = 1, .inputmode = 1, .inputlen = 3, .inputcursor = 2, .inputcap = 8, .nmatches = 2, .match_cap = 4, .current = 1, .active = 0 }, 6, 2);

    try std.testing.expectEqual(@as(usize, 8), moved.update.inputcursor);
    try std.testing.expectEqual(@as(c_int, 1), moved.effect.redraw);
    try std.testing.expectEqual(@as(usize, 0), clear.update.inputlen);
    try std.testing.expectEqual(@as(c_int, 1), clear.effect.refresh_search);
    try std.testing.expectEqual(@as(c_int, 1), prompt.effect.alloc_input);
    try std.testing.expectEqual(@as(c_int, 1), set.effect.alloc_query);
    try std.testing.expectEqual(@as(c_int, 1), st_searchstep(1, 3, 2, 1).run);
    try std.testing.expectEqual(@as(c_int, 3), st_searchjumpplan(1, 0, 1, 0, 3).new_scr);
    try std.testing.expectEqual(@as(c_int, 1), st_searchdeleteplan(2, 5, 9).run);
}
