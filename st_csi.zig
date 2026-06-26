//! st_csi.zig 负责 CSI 解析和 `csihandle` 顶层动作聚合。
//! [输入]: `csiescseq.buf`、CSI mode/参数、光标位置和终端尺寸，由 C 收集并显式传入。
//! [输出]: `ZigCsiParse` 和 `ZigCsiExecPlan`，包含解析结果、command kind 和子 plan。
//! [副作用边界]: 不执行移动、清屏、mode 设置、tty 写入或 X11 调用；C executor 负责真实副作用。
//! [定位]: 收敛 `csiparse(...)` 和 `csihandle(...)` 的纯解析、分类和范围规划。

const std = @import("std");

const csi_arg_siz = 16;

const ZigCsiParse = extern struct {
    priv: c_char,
    arg: [csi_arg_siz]c_int,
    narg: c_int,
    mode: [2]c_char,
};

const ZigClearRect = extern struct {
    x1: c_int,
    y1: c_int,
    x2: c_int,
    y2: c_int,
};

const ZigErasePlan = extern struct {
    kind: c_int,
    count: c_int,
    rects: [2]ZigClearRect,
};

const ZigCursorPlan = extern struct {
    kind: c_int,
    x: c_int,
    y: c_int,
};

const ZigEditPlan = extern struct {
    kind: c_int,
    count: c_int,
    rect: ZigClearRect,
};

const ZigLightPlan = extern struct {
    kind: c_int,
    value: c_int,
    x: c_int,
    y: c_int,
};

const ZigStatePlan = extern struct {
    kind: c_int,
    top: c_int,
    bottom: c_int,
};

const ZigMiscPlan = extern struct {
    kind: c_int,
    value: c_int,
    extra: c_int,
};

const ZigCsiExecPlan = extern struct {
    kind: c_int,
    mode_set: c_int,
    edit: ZigEditPlan,
    cursor: ZigCursorPlan,
    misc: ZigMiscPlan,
    light: ZigLightPlan,
    erase: ZigErasePlan,
    state: ZigStatePlan,
};

const csi_exec_unknown = 0;
const csi_exec_edit = 1;
const csi_exec_cursor = 2;
const csi_exec_misc = 3;
const csi_exec_light = 4;
const csi_exec_erase = 5;
const csi_exec_mode = 6;
const csi_exec_attr = 7;
const csi_exec_state = 8;

const cursor_move_to = 0;
const cursor_move_to_abs = 1;
const cursor_unknown = 2;

const edit_insert_blank = 0;
const edit_scroll_up = 1;
const edit_scroll_down = 2;
const edit_insert_blank_line = 3;
const edit_delete_line = 4;
const edit_clear_region = 5;
const edit_delete_char = 6;
const edit_unknown = 7;

const erase_ok = 0;
const erase_unknown = 1;

const light_none = 0;
const light_clear_tab_current = 1;
const light_clear_tab_all = 2;
const light_put_tab = 3;
const light_write_vtident = 4;
const light_write_cursor_position = 5;
const light_unknown = 6;

const state_unknown = 0;
const state_set_scroll = 1;
const state_save_cursor = 2;
const state_load_cursor = 3;

const misc_none = 0;
const misc_media_dump = 1;
const misc_media_dump_line = 2;
const misc_media_dump_sel = 3;
const misc_media_print_off = 4;
const misc_media_print_on = 5;
const misc_repeat_last = 6;
const misc_set_cursor_style = 7;
const misc_unknown = 8;

export fn st_csiparse(buf: [*]const u8, len: usize) ZigCsiParse {
    return (CsiParser{ .input = buf[0..len] }).parse();
}

export fn st_csiexecplan(mode0: c_char, mode1: c_char, priv: c_char, arg: [*]const c_int, len: c_int, x: c_int, y: c_int, col: c_int, row: c_int) ZigCsiExecPlan {
    const args = arg[0..@intCast(len)];
    return (CsiExec{ .mode0 = mode0, .mode1 = mode1, .private = priv != 0, .args = args, .x = x, .y = y, .col = col, .row = row }).plan();
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

const CsiExec = struct {
    mode0: c_char,
    mode1: c_char,
    private: bool,
    args: []const c_int,
    x: c_int,
    y: c_int,
    col: c_int,
    row: c_int,

    fn plan(self: CsiExec) ZigCsiExecPlan {
        var result = emptyExec();

        switch (self.mode0) {
            '@', 'S', 'T', 'L', 'M', 'X', 'P' => {
                result.kind = csi_exec_edit;
                result.edit = self.editPlan();
            },
            'A', 'B', 'e', 'C', 'a', 'D', 'E', 'F', 'G', '`', 'H', 'f', 'd' => {
                result.kind = csi_exec_cursor;
                result.cursor = self.cursorPlan();
            },
            'i', 'b', ' ' => {
                result.misc = self.miscPlan();
                result.kind = if (result.misc.kind == misc_unknown) csi_exec_unknown else csi_exec_misc;
            },
            'c', 'g', 'I', 'Z', 'n' => {
                result.light = self.lightPlan();
                result.kind = if (result.light.kind == light_unknown) csi_exec_unknown else csi_exec_light;
            },
            'J', 'K' => {
                result.erase = self.erasePlan();
                result.kind = if (result.erase.kind == erase_ok) csi_exec_erase else csi_exec_unknown;
            },
            'l', 'h' => {
                result.kind = csi_exec_mode;
                result.mode_set = if (self.mode0 == 'h') 1 else 0;
            },
            'm' => result.kind = csi_exec_attr,
            'r', 's', 'u' => {
                result.state = self.statePlan();
                result.kind = if (result.state.kind == state_unknown) csi_exec_unknown else csi_exec_state;
            },
            else => result.kind = csi_exec_unknown,
        }

        return result;
    }

    fn cursorPlan(self: CsiExec) ZigCursorPlan {
        const arg0 = defaultOne(self.args, 0);
        const arg1 = defaultOne(self.args, 1);
        return switch (self.mode0) {
            'A' => .{ .kind = cursor_move_to, .x = self.x, .y = self.y - arg0 },
            'B', 'e' => .{ .kind = cursor_move_to, .x = self.x, .y = self.y + arg0 },
            'C', 'a' => .{ .kind = cursor_move_to, .x = self.x + arg0, .y = self.y },
            'D' => .{ .kind = cursor_move_to, .x = self.x - arg0, .y = self.y },
            'E' => .{ .kind = cursor_move_to, .x = 0, .y = self.y + arg0 },
            'F' => .{ .kind = cursor_move_to, .x = 0, .y = self.y - arg0 },
            'G', '`' => .{ .kind = cursor_move_to, .x = arg0 - 1, .y = self.y },
            'H', 'f' => .{ .kind = cursor_move_to_abs, .x = arg1 - 1, .y = arg0 - 1 },
            'd' => .{ .kind = cursor_move_to_abs, .x = self.x, .y = arg0 - 1 },
            else => .{ .kind = cursor_unknown, .x = self.x, .y = self.y },
        };
    }

    fn editPlan(self: CsiExec) ZigEditPlan {
        const count = defaultOne(self.args, 0);
        return switch (self.mode0) {
            '@' => .{ .kind = edit_insert_blank, .count = count, .rect = zeroRect() },
            'S' => .{ .kind = edit_scroll_up, .count = count, .rect = zeroRect() },
            'T' => .{ .kind = edit_scroll_down, .count = count, .rect = zeroRect() },
            'L' => .{ .kind = edit_insert_blank_line, .count = count, .rect = zeroRect() },
            'M' => .{ .kind = edit_delete_line, .count = count, .rect = zeroRect() },
            'P' => .{ .kind = edit_delete_char, .count = count, .rect = zeroRect() },
            'X' => .{ .kind = edit_clear_region, .count = count, .rect = .{ .x1 = self.x, .y1 = self.y, .x2 = self.x + count - 1, .y2 = self.y } },
            else => .{ .kind = edit_unknown, .count = count, .rect = zeroRect() },
        };
    }

    fn erasePlan(self: CsiExec) ZigErasePlan {
        var result = ZigErasePlan{ .kind = erase_ok, .count = 0, .rects = std.mem.zeroes([2]ZigClearRect) };
        switch (self.mode0) {
            'J' => switch (defaultZero(self.args, 0)) {
                0 => {
                    addEraseRect(&result, self.x, self.y, self.col - 1, self.y);
                    if (self.y < self.row - 1) addEraseRect(&result, 0, self.y + 1, self.col - 1, self.row - 1);
                },
                1 => {
                    if (self.y > 1) addEraseRect(&result, 0, 0, self.col - 1, self.y - 1);
                    addEraseRect(&result, 0, self.y, self.x, self.y);
                },
                2 => addEraseRect(&result, 0, 0, self.col - 1, self.row - 1),
                else => result.kind = erase_unknown,
            },
            'K' => switch (defaultZero(self.args, 0)) {
                0 => addEraseRect(&result, self.x, self.y, self.col - 1, self.y),
                1 => addEraseRect(&result, 0, self.y, self.x, self.y),
                2 => addEraseRect(&result, 0, self.y, self.col - 1, self.y),
                else => result.kind = erase_unknown,
            },
            else => result.kind = erase_unknown,
        }
        return result;
    }

    fn lightPlan(self: CsiExec) ZigLightPlan {
        const arg0 = defaultZero(self.args, 0);
        return switch (self.mode0) {
            'c' => if (arg0 == 0)
                .{ .kind = light_write_vtident, .value = 0, .x = 0, .y = 0 }
            else
                .{ .kind = light_none, .value = 0, .x = 0, .y = 0 },
            'g' => switch (arg0) {
                0 => .{ .kind = light_clear_tab_current, .value = 0, .x = 0, .y = 0 },
                3 => .{ .kind = light_clear_tab_all, .value = 0, .x = 0, .y = 0 },
                else => .{ .kind = light_unknown, .value = arg0, .x = 0, .y = 0 },
            },
            'I' => .{ .kind = light_put_tab, .value = countArg(self.args), .x = 0, .y = 0 },
            'Z' => .{ .kind = light_put_tab, .value = -countArg(self.args), .x = 0, .y = 0 },
            'n' => if (arg0 == 6)
                .{ .kind = light_write_cursor_position, .value = 0, .x = self.x + 1, .y = self.y + 1 }
            else
                .{ .kind = light_none, .value = 0, .x = 0, .y = 0 },
            else => .{ .kind = light_unknown, .value = 0, .x = 0, .y = 0 },
        };
    }

    fn miscPlan(self: CsiExec) ZigMiscPlan {
        const arg0 = defaultZero(self.args, 0);
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

    fn statePlan(self: CsiExec) ZigStatePlan {
        return switch (self.mode0) {
            'r' => if (self.private)
                .{ .kind = state_unknown, .top = 0, .bottom = 0 }
            else
                .{ .kind = state_set_scroll, .top = defaultOne(self.args, 0) - 1, .bottom = defaultArg(self.args, 1, self.row) - 1 },
            's' => .{ .kind = state_save_cursor, .top = 0, .bottom = 0 },
            'u' => .{ .kind = state_load_cursor, .top = 0, .bottom = 0 },
            else => .{ .kind = state_unknown, .top = 0, .bottom = 0 },
        };
    }
};

fn emptyExec() ZigCsiExecPlan {
    return .{
        .kind = csi_exec_unknown,
        .mode_set = 0,
        .edit = .{ .kind = edit_unknown, .count = 0, .rect = zeroRect() },
        .cursor = .{ .kind = cursor_unknown, .x = 0, .y = 0 },
        .misc = .{ .kind = misc_unknown, .value = 0, .extra = 0 },
        .light = .{ .kind = light_unknown, .value = 0, .x = 0, .y = 0 },
        .erase = .{ .kind = erase_unknown, .count = 0, .rects = std.mem.zeroes([2]ZigClearRect) },
        .state = .{ .kind = state_unknown, .top = 0, .bottom = 0 },
    };
}

fn addEraseRect(plan: *ZigErasePlan, x1: c_int, y1: c_int, x2: c_int, y2: c_int) void {
    if (plan.count >= plan.rects.len) return;
    plan.rects[@intCast(plan.count)] = .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 };
    plan.count += 1;
}

fn zeroRect() ZigClearRect {
    return .{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 0 };
}

fn defaultArg(args: []const c_int, index: usize, fallback: c_int) c_int {
    if (index >= args.len) return fallback;
    return if (args[index] == 0) fallback else args[index];
}

fn defaultOne(args: []const c_int, index: usize) c_int {
    return defaultArg(args, index, 1);
}

fn defaultZero(args: []const c_int, index: usize) c_int {
    if (index >= args.len) return 0;
    return args[index];
}

fn countArg(args: []const c_int) c_int {
    const value = defaultZero(args, 0);
    return if (value == 0) 1 else value;
}

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
    try std.testing.expectEqual(@as(c_int, 1), parsed.narg);
    try std.testing.expectEqual(@as(c_int, 25), parsed.arg[0]);
    try std.testing.expectEqual(@as(c_char, 'h'), parsed.mode[0]);
}

test "csi exec groups cursor command" {
    const plan = st_csiexecplan('C', 0, 0, &[_]c_int{3}, 1, 7, 9, 80, 24);
    const absolute = st_csiexecplan('H', 0, 0, &[_]c_int{ 4, 6 }, 2, 7, 9, 80, 24);
    try std.testing.expectEqual(@as(c_int, csi_exec_cursor), plan.kind);
    try std.testing.expectEqual(@as(c_int, 10), plan.cursor.x);
    try std.testing.expectEqual(@as(c_int, cursor_move_to_abs), absolute.cursor.kind);
    try std.testing.expectEqual(@as(c_int, 5), absolute.cursor.x);
    try std.testing.expectEqual(@as(c_int, 3), absolute.cursor.y);
}

test "csi exec groups edit command" {
    const insert = st_csiexecplan('@', 0, 0, &[_]c_int{0}, 1, 3, 4, 80, 24);
    const clear = st_csiexecplan('X', 0, 0, &[_]c_int{4}, 1, 5, 6, 80, 24);

    try std.testing.expectEqual(@as(c_int, csi_exec_edit), insert.kind);
    try std.testing.expectEqual(@as(c_int, edit_insert_blank), insert.edit.kind);
    try std.testing.expectEqual(@as(c_int, 1), insert.edit.count);
    try std.testing.expectEqual(@as(c_int, edit_clear_region), clear.edit.kind);
    try std.testing.expectEqual(ZigClearRect{ .x1 = 5, .y1 = 6, .x2 = 8, .y2 = 6 }, clear.edit.rect);
}

test "csi exec groups erase and rejects invalid erase arg" {
    const screen = st_csiexecplan('J', 0, 0, &[_]c_int{0}, 1, 3, 4, 10, 8);
    const erase = st_csiexecplan('K', 0, 0, &[_]c_int{2}, 1, 5, 6, 80, 24);
    const invalid = st_csiexecplan('K', 0, 0, &[_]c_int{9}, 1, 5, 6, 80, 24);
    try std.testing.expectEqual(@as(c_int, 2), screen.erase.count);
    try std.testing.expectEqual(ZigClearRect{ .x1 = 3, .y1 = 4, .x2 = 9, .y2 = 4 }, screen.erase.rects[0]);
    try std.testing.expectEqual(@as(c_int, csi_exec_erase), erase.kind);
    try std.testing.expectEqual(@as(c_int, csi_exec_unknown), invalid.kind);
}

test "csi exec groups light and misc commands" {
    const light = st_csiexecplan('n', 0, 0, &[_]c_int{6}, 1, 7, 9, 80, 24);
    const misc = st_csiexecplan('b', 0, 0, &[_]c_int{0}, 1, 7, 9, 80, 24);
    const cursor_style = st_csiexecplan(' ', 'q', 0, &[_]c_int{3}, 1, 7, 9, 80, 24);
    const invalid = st_csiexecplan(' ', 'x', 0, &[_]c_int{3}, 1, 7, 9, 80, 24);

    try std.testing.expectEqual(@as(c_int, csi_exec_light), light.kind);
    try std.testing.expectEqual(@as(c_int, light_write_cursor_position), light.light.kind);
    try std.testing.expectEqual(@as(c_int, 8), light.light.x);
    try std.testing.expectEqual(@as(c_int, 10), light.light.y);
    try std.testing.expectEqual(@as(c_int, csi_exec_misc), misc.kind);
    try std.testing.expectEqual(@as(c_int, misc_repeat_last), misc.misc.kind);
    try std.testing.expectEqual(@as(c_int, 1), misc.misc.value);
    try std.testing.expectEqual(@as(c_int, misc_set_cursor_style), cursor_style.misc.kind);
    try std.testing.expectEqual(@as(c_int, csi_exec_unknown), invalid.kind);
}

test "csi exec groups mode attr and state" {
    try std.testing.expectEqual(@as(c_int, csi_exec_mode), st_csiexecplan('h', 0, 0, &[_]c_int{25}, 1, 0, 0, 80, 24).kind);
    try std.testing.expectEqual(@as(c_int, 1), st_csiexecplan('h', 0, 0, &[_]c_int{25}, 1, 0, 0, 80, 24).mode_set);
    try std.testing.expectEqual(@as(c_int, csi_exec_attr), st_csiexecplan('m', 0, 0, &[_]c_int{0}, 1, 0, 0, 80, 24).kind);
    try std.testing.expectEqual(@as(c_int, csi_exec_state), st_csiexecplan('r', 0, 0, &[_]c_int{ 2, 8 }, 2, 0, 0, 80, 24).kind);
    try std.testing.expectEqual(@as(c_int, 1), st_csiexecplan('r', 0, 0, &[_]c_int{ 2, 8 }, 2, 0, 0, 80, 24).state.top);
    try std.testing.expectEqual(@as(c_int, 7), st_csiexecplan('r', 0, 0, &[_]c_int{ 2, 8 }, 2, 0, 0, 80, 24).state.bottom);
    try std.testing.expectEqual(@as(c_int, csi_exec_unknown), st_csiexecplan('r', 0, '?', &[_]c_int{ 2, 8 }, 2, 0, 0, 80, 24).kind);
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
