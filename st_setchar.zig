//! st_setchar.zig 是当前最厚的 Zig 迁移模块，承载字符写入、STR 收集、ESC/control 状态执行等核心逻辑。
//! [输入]: C 侧传入 rune、glyph 属性、当前行 buffer、ESC 状态、CSI/STR 缓冲区和必要的光标/终端尺寸字段。
//! [输出]: 通过 extern struct 返回写入结果、prepare plan、STR collect 结果、ESC flow 结果或 control/ESC action。
//! [副作用边界]: 可修改传入的局部 glyph 行和显式传入的状态指针；不直接调用 X11、tty、滚屏、selection、allocator 或全局 `term`。
//! [定位]: 这是 `tsetchar(...)` 与 `tputc(...)` 逐步迁移的汇聚点，目标是在不扩大 C/Zig 全局状态耦合的前提下持续压薄 `st.c`。

const std = @import("std");

pub const ZigGlyph = extern struct {
    u: u32,
    mode: c_ushort,
    fg: u32,
    bg: u32,
};

pub const ZigPutcWriteResult = extern struct {
    advance: c_int,
    next_x: c_int,
};

pub const ZigPutcPreparePlan = extern struct {
    clear_selection: c_int,
    wrapnext: c_int,
    overflow: c_int,
};

pub const ZigStrCollectExec = extern struct {
    kind: c_int,
    new_esc: c_int,
    new_len: usize,
    new_size: usize,
};

pub const ZigEscFlowExec = extern struct {
    kind: c_int,
    handle_csi: c_int,
    new_csi_len: usize,
};

pub const ZigEscFlowAfter = extern struct {
    clear_esc: c_int,
    new_esc: c_int,
    stop: c_int,
};

pub const ZigEscPlan = extern struct {
    kind: c_int,
    value: c_int,
    ret: c_int,
};

pub const ZigEscExec = extern struct {
    action: c_int,
    ret: c_int,
};

pub const ZigControlExec = extern struct {
    action: c_int,
    clear_str: c_int,
};

const ZigControlPlan = extern struct {
    kind: c_int,
    value: c_int,
};

const cs_graphic0 = 0;
const attr_wide: c_ushort = 1 << 9;
const attr_wdummy: c_ushort = 1 << 10;
const putc_advance_move = 0;
const putc_advance_wrapnext = 1;
const cursor_wrapnext = 1;
const str_collect_append = 0;
const str_collect_finish = 1;
const str_collect_grow = 2;
const str_collect_abort = 3;
const esc_start: c_int = 1;
const esc_csi: c_int = 2;
const esc_altcharset: c_int = 8;
const esc_test: c_int = 32;
const esc_utf8: c_int = 64;
const esc_str: c_int = 4;
const esc_str_end: c_int = 16;
const esc_flow_none = 0;
const esc_flow_csi = 1;
const esc_flow_utf8 = 2;
const esc_flow_altcharset = 3;
const esc_flow_test = 4;
const esc_flow_esc = 5;
const esc_unknown = 0;
const esc_set_csi = 1;
const esc_set_test = 2;
const esc_set_utf8 = 3;
const esc_start_str = 4;
const esc_lock_shift = 5;
const esc_set_altcharset = 6;
const esc_ind = 7;
const esc_nel = 8;
const esc_hts = 9;
const esc_ri = 10;
const esc_decid = 11;
const esc_ris = 12;
const esc_keypad_app = 13;
const esc_keypad_normal = 14;
const esc_cursor_save = 15;
const esc_cursor_load = 16;
const esc_st = 17;
const esc_action_none = 0;
const esc_action_start_str = 1;
const esc_action_ind = 2;
const esc_action_nel = 3;
const esc_action_ri = 4;
const esc_action_decid = 5;
const esc_action_ris = 6;
const esc_action_keypad_app = 7;
const esc_action_keypad_normal = 8;
const esc_action_cursor_save = 9;
const esc_action_cursor_load = 10;
const esc_action_st = 11;
const esc_action_unknown = 12;
const ctl_none = 0;
const ctl_tab = 1;
const ctl_backspace = 2;
const ctl_carriage_return = 3;
const ctl_linefeed = 4;
const ctl_bell = 5;
const ctl_escape = 6;
const ctl_lock_shift = 7;
const ctl_substitute = 8;
const ctl_cancel = 9;
const ctl_next_line = 10;
const ctl_set_tab_stop = 11;
const ctl_decid = 12;
const ctl_start_str = 13;
const ctl_action_none = 0;
const ctl_action_tab = 1;
const ctl_action_backspace = 2;
const ctl_action_carriage_return = 3;
const ctl_action_linefeed = 4;
const ctl_action_bell = 5;
const ctl_action_escape = 6;
const ctl_action_substitute = 7;
const ctl_action_cancel = 8;
const ctl_action_next_line = 9;
const ctl_action_decid = 10;
const ctl_action_start_str = 11;

const graphic0_map = [_]u32{
    0x2191, 0x2193, 0x2192, 0x2190, 0x2588, 0x259A, 0x2603,
    0,      0,      0,      0,      0,      0,      0,
    0,      0,      0,      0,      0,      0,      0,
    0,      0,      0,      0,      0,      0,      0,
    0,      0,      0x20,   0x25C6, 0x2592, 0x2409, 0x240C,
    0x240D, 0x240A, 0x00B0, 0x00B1, 0x2424, 0x240B, 0x2518,
    0x2510, 0x250C, 0x2514, 0x253C, 0x23BA, 0x23BB, 0x2500,
    0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534, 0x252C, 0x2502,
    0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7,
};

export fn st_tsetchar(rune: u32, attr: *const ZigGlyph, line: [*]ZigGlyph, dirty: *c_int, x: c_int, col: c_int, trantbl: c_int) void {
    const next_rune = translateRune(rune, trantbl);
    const current_mode = line[@intCast(x)].mode;

    if ((current_mode & attr_wide) != 0 and x + 1 < col) {
        line[@intCast(x + 1)].u = ' ';
        line[@intCast(x + 1)].mode &= ~attr_wdummy;
    } else if ((current_mode & attr_wdummy) != 0 and x > 0) {
        line[@intCast(x - 1)].u = ' ';
        line[@intCast(x - 1)].mode &= ~attr_wide;
    }

    dirty.* = 1;
    line[@intCast(x)] = attr.*;
    line[@intCast(x)].u = next_rune;
}

export fn st_tputcwrite(rune: u32, width: c_int, attr: *const ZigGlyph, line: [*]ZigGlyph, dirty: *c_int, x: c_int, col: c_int, trantbl: c_int, insert_mode: c_int) ZigPutcWriteResult {
    if (insert_mode != 0 and x + width < col) {
        shiftRight(line, x, width, col);
    }

    st_tsetchar(rune, attr, line, dirty, x, col, trantbl);

    if (width == 2) {
        line[@intCast(x)].mode |= attr_wide;
        if (x + 1 < col) {
            line[@intCast(x + 1)].u = 0;
            line[@intCast(x + 1)].mode = attr_wdummy;
        }
    }

    return .{
        .advance = if (x + width < col) putc_advance_move else putc_advance_wrapnext,
        .next_x = x + width,
    };
}

export fn st_tputcprepare(selected_current: c_int, mode_wrap: c_int, cursor_state: c_int, x: c_int, width: c_int, col: c_int) ZigPutcPreparePlan {
    return .{
        .clear_selection = if (selected_current != 0) 1 else 0,
        .wrapnext = if (mode_wrap != 0 and (cursor_state & cursor_wrapnext) != 0) 1 else 0,
        .overflow = if (x + width > col) 1 else 0,
    };
}

export fn st_tcollectstr(rune: u32, esc: c_int, buf: [*]u8, len: usize, chunk: [*]const u8, chunk_len: usize, size: usize) ZigStrCollectExec {
    const plan = planStrCollect(rune, len, chunk_len, size);

    if (plan.kind == str_collect_finish) {
        return .{
            .kind = plan.kind,
            .new_esc = (esc & ~(esc_start | esc_str)) | esc_str_end,
            .new_len = len,
            .new_size = size,
        };
    }

    if (plan.kind == str_collect_abort) {
        return .{
            .kind = plan.kind,
            .new_esc = esc,
            .new_len = len,
            .new_size = size,
        };
    }

    if (plan.kind == str_collect_grow) {
        return .{
            .kind = plan.kind,
            .new_esc = esc,
            .new_len = len,
            .new_size = plan.new_size,
        };
    }

    @memcpy(buf[len .. len + @as(usize, @intCast(chunk_len))], chunk[0..@intCast(chunk_len)]);
    return .{
        .kind = plan.kind,
        .new_esc = esc,
        .new_len = len + @as(usize, @intCast(chunk_len)),
        .new_size = size,
    };
}

export fn st_tescflow(esc: c_int, rune: u32, csi_buf: [*]u8, csi_len: usize, csi_cap: usize) ZigEscFlowExec {
    if ((esc & esc_csi) != 0) {
        csi_buf[csi_len] = @truncate(rune);
        const new_len = csi_len + 1;
        const handle_csi: c_int = if ((0x40 <= rune and rune <= 0x7E) or csi_len >= csi_cap - 1) 1 else 0;
        return .{ .kind = esc_flow_csi, .handle_csi = handle_csi, .new_csi_len = new_len };
    }
    if ((esc & esc_utf8) != 0) return .{ .kind = esc_flow_utf8, .handle_csi = 0, .new_csi_len = csi_len };
    if ((esc & esc_altcharset) != 0) return .{ .kind = esc_flow_altcharset, .handle_csi = 0, .new_csi_len = csi_len };
    if ((esc & esc_test) != 0) return .{ .kind = esc_flow_test, .handle_csi = 0, .new_csi_len = csi_len };
    if ((esc & esc_start) != 0) return .{ .kind = esc_flow_esc, .handle_csi = 0, .new_csi_len = csi_len };
    return .{ .kind = esc_flow_none, .handle_csi = 0, .new_csi_len = csi_len };
}

export fn st_tcontrolafter(esc: c_int) c_int {
    return if (esc == 0) 1 else 0;
}

export fn st_tescflowafter(kind: c_int, action_done: c_int) ZigEscFlowAfter {
    if ((kind == esc_flow_csi or kind == esc_flow_esc) and action_done == 0) {
        return .{ .clear_esc = 0, .new_esc = 0, .stop = 1 };
    }

    return .{ .clear_esc = 1, .new_esc = 0, .stop = 1 };
}

fn planEsc(ascii: u8) ZigEscPlan {
    return switch (ascii) {
        '[' => .{ .kind = esc_set_csi, .value = 0, .ret = 0 },
        '#' => .{ .kind = esc_set_test, .value = 0, .ret = 0 },
        '%' => .{ .kind = esc_set_utf8, .value = 0, .ret = 0 },
        'P', '_', '^', ']', 'k' => .{ .kind = esc_start_str, .value = ascii, .ret = 0 },
        'n', 'o' => .{ .kind = esc_lock_shift, .value = 2 + @as(c_int, ascii - 'n'), .ret = 1 },
        '(', ')', '*', '+' => .{ .kind = esc_set_altcharset, .value = @as(c_int, ascii - '('), .ret = 0 },
        'D' => .{ .kind = esc_ind, .value = 0, .ret = 1 },
        'E' => .{ .kind = esc_nel, .value = 0, .ret = 1 },
        'H' => .{ .kind = esc_hts, .value = 0, .ret = 1 },
        'M' => .{ .kind = esc_ri, .value = 0, .ret = 1 },
        'Z' => .{ .kind = esc_decid, .value = 0, .ret = 1 },
        'c' => .{ .kind = esc_ris, .value = 0, .ret = 1 },
        '=' => .{ .kind = esc_keypad_app, .value = 0, .ret = 1 },
        '>' => .{ .kind = esc_keypad_normal, .value = 0, .ret = 1 },
        '7' => .{ .kind = esc_cursor_save, .value = 0, .ret = 1 },
        '8' => .{ .kind = esc_cursor_load, .value = 0, .ret = 1 },
        '\\' => .{ .kind = esc_st, .value = 0, .ret = 1 },
        else => .{ .kind = esc_unknown, .value = 0, .ret = 1 },
    };
}

export fn st_tescexec(ascii: u8, esc: *c_int, charset: *c_int, icharset: *c_int, tabs: [*]c_int, x: c_int) ZigEscExec {
    const plan = planEsc(ascii);

    switch (plan.kind) {
        esc_set_csi => esc.* |= esc_csi,
        esc_set_test => esc.* |= esc_test,
        esc_set_utf8 => esc.* |= esc_utf8,
        esc_lock_shift => charset.* = plan.value,
        esc_set_altcharset => {
            icharset.* = plan.value;
            esc.* |= esc_altcharset;
        },
        esc_hts => tabs[@intCast(x)] = 1,
        else => {},
    }

    return .{
        .action = escAction(plan.kind),
        .ret = plan.ret,
    };
}

export fn st_tcontrolexec(ascii: u8, esc: *c_int, charset: *c_int, tabs: [*]c_int, x: c_int) ZigControlExec {
    const plan = planControl(ascii);

    switch (plan.kind) {
        ctl_escape => {
            esc.* &= ~(esc_csi | esc_altcharset | esc_test);
            esc.* |= esc_start;
        },
        ctl_lock_shift => charset.* = plan.value,
        ctl_set_tab_stop => tabs[@intCast(x)] = 1,
        else => {},
    }

    return .{
        .action = controlAction(plan.kind),
        .clear_str = if (clearsString(plan.kind)) 1 else 0,
    };
}

fn planControl(ascii: u8) ZigControlPlan {
    return switch (ascii) {
        '\t' => .{ .kind = ctl_tab, .value = 0 },
        0x08 => .{ .kind = ctl_backspace, .value = 0 },
        '\r' => .{ .kind = ctl_carriage_return, .value = 0 },
        0x0c, 0x0b, '\n' => .{ .kind = ctl_linefeed, .value = 0 },
        0x07 => .{ .kind = ctl_bell, .value = 0 },
        '\x1b' => .{ .kind = ctl_escape, .value = 0 },
        '\x0e', '\x0f' => .{ .kind = ctl_lock_shift, .value = 1 - @as(c_int, ascii - '\x0e') },
        '\x1a' => .{ .kind = ctl_substitute, .value = 0 },
        '\x18' => .{ .kind = ctl_cancel, .value = 0 },
        '\x05', '\x00', '\x11', '\x13', 0x7f => .{ .kind = ctl_none, .value = 0 },
        0x80, 0x81, 0x82, 0x83, 0x84 => .{ .kind = ctl_none, .value = 0 },
        0x85 => .{ .kind = ctl_next_line, .value = 1 },
        0x86, 0x87 => .{ .kind = ctl_none, .value = 0 },
        0x88 => .{ .kind = ctl_set_tab_stop, .value = 0 },
        0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99 => .{ .kind = ctl_none, .value = 0 },
        0x9a => .{ .kind = ctl_decid, .value = 0 },
        0x9b, 0x9c => .{ .kind = ctl_none, .value = 0 },
        0x90, 0x9d, 0x9e, 0x9f => .{ .kind = ctl_start_str, .value = ascii },
        else => .{ .kind = ctl_none, .value = 0 },
    };
}

fn controlAction(kind: c_int) c_int {
    return switch (kind) {
        ctl_tab => ctl_action_tab,
        ctl_backspace => ctl_action_backspace,
        ctl_carriage_return => ctl_action_carriage_return,
        ctl_linefeed => ctl_action_linefeed,
        ctl_bell => ctl_action_bell,
        ctl_escape => ctl_action_escape,
        ctl_substitute => ctl_action_substitute,
        ctl_cancel => ctl_action_cancel,
        ctl_next_line => ctl_action_next_line,
        ctl_decid => ctl_action_decid,
        ctl_start_str => ctl_action_start_str,
        else => ctl_action_none,
    };
}

fn clearsString(kind: c_int) bool {
    return switch (kind) {
        ctl_bell, ctl_substitute, ctl_cancel, ctl_next_line, ctl_set_tab_stop, ctl_decid => true,
        else => false,
    };
}

fn escAction(kind: c_int) c_int {
    return switch (kind) {
        esc_start_str => esc_action_start_str,
        esc_ind => esc_action_ind,
        esc_nel => esc_action_nel,
        esc_ri => esc_action_ri,
        esc_decid => esc_action_decid,
        esc_ris => esc_action_ris,
        esc_keypad_app => esc_action_keypad_app,
        esc_keypad_normal => esc_action_keypad_normal,
        esc_cursor_save => esc_action_cursor_save,
        esc_cursor_load => esc_action_cursor_load,
        esc_st => esc_action_st,
        esc_unknown => esc_action_unknown,
        else => esc_action_none,
    };
}

fn translateRune(rune: u32, trantbl: c_int) u32 {
    if (trantbl == cs_graphic0 and 0x41 <= rune and rune <= 0x7E) {
        const mapped = graphic0_map[rune - 0x41];
        if (mapped != 0) {
            return mapped;
        }
    }

    return rune;
}

fn shiftRight(line: [*]ZigGlyph, x: c_int, width: c_int, col: c_int) void {
    const move_count: usize = @intCast(col - x - width);
    const base_x: usize = @intCast(x);
    const gap: usize = @intCast(width);

    var i = move_count;
    while (i > 0) {
        i -= 1;
        line[base_x + gap + i] = line[base_x + i];
    }
}

fn planStrCollect(rune: u32, current_len: usize, chunk_len: usize, current_size: usize) ZigStrCollectExec {
    if (terminatesString(rune)) {
        return .{ .kind = str_collect_finish, .new_esc = 0, .new_len = current_len, .new_size = current_size };
    }

    if (current_len + chunk_len >= current_size) {
        if (current_size > (std.math.maxInt(usize) - 4) / 2) {
            return .{ .kind = str_collect_abort, .new_esc = 0, .new_len = current_len, .new_size = current_size };
        }
        return .{ .kind = str_collect_grow, .new_esc = 0, .new_len = current_len, .new_size = current_size * 2 };
    }

    return .{ .kind = str_collect_append, .new_esc = 0, .new_len = current_len, .new_size = current_size };
}

fn terminatesString(rune: u32) bool {
    return rune == 0x07 or rune == 0x18 or rune == 0x1A or rune == 0x1B or (0x80 <= rune and rune <= 0x9F);
}

test "tsetchar writes translated graphic rune" {
    var line = [_]ZigGlyph{
        .{ .u = 0, .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = 0, .mode = 0, .fg = 0, .bg = 0 },
    };
    const attr = ZigGlyph{ .u = 0, .mode = 7, .fg = 1, .bg = 2 };
    var dirty: c_int = 0;

    st_tsetchar('q', &attr, &line, &dirty, 0, 2, cs_graphic0);

    try std.testing.expectEqual(@as(c_int, 1), dirty);
    try std.testing.expectEqual(@as(u32, 0x2500), line[0].u);
    try std.testing.expectEqual(@as(c_ushort, 7), line[0].mode);
    try std.testing.expectEqual(@as(u32, 1), line[0].fg);
    try std.testing.expectEqual(@as(u32, 2), line[0].bg);
}

test "tsetchar clears right dummy when replacing wide cell" {
    var line = [_]ZigGlyph{
        .{ .u = '中', .mode = attr_wide, .fg = 0, .bg = 0 },
        .{ .u = 0, .mode = attr_wdummy, .fg = 0, .bg = 0 },
        .{ .u = 0, .mode = 0, .fg = 0, .bg = 0 },
    };
    const attr = ZigGlyph{ .u = 0, .mode = 1, .fg = 3, .bg = 4 };
    var dirty: c_int = 0;

    st_tsetchar('A', &attr, &line, &dirty, 0, 3, 1);

    try std.testing.expectEqual(@as(u32, ' '), line[1].u);
    try std.testing.expectEqual(@as(c_ushort, 0), line[1].mode);
    try std.testing.expectEqual(@as(u32, 'A'), line[0].u);
}

test "tsetchar clears left wide when replacing dummy cell" {
    var line = [_]ZigGlyph{
        .{ .u = '中', .mode = attr_wide, .fg = 0, .bg = 0 },
        .{ .u = 0, .mode = attr_wdummy, .fg = 0, .bg = 0 },
        .{ .u = 0, .mode = 0, .fg = 0, .bg = 0 },
    };
    const attr = ZigGlyph{ .u = 0, .mode = 2, .fg = 5, .bg = 6 };
    var dirty: c_int = 0;

    st_tsetchar('B', &attr, &line, &dirty, 1, 3, 1);

    try std.testing.expectEqual(@as(u32, ' '), line[0].u);
    try std.testing.expectEqual(@as(c_ushort, 0), line[0].mode);
    try std.testing.expectEqual(@as(u32, 'B'), line[1].u);
    try std.testing.expectEqual(@as(c_ushort, 2), line[1].mode);
}

test "tputcwrite shifts line in insert mode" {
    var line = [_]ZigGlyph{
        .{ .u = '甲', .mode = 1, .fg = 1, .bg = 1 },
        .{ .u = '乙', .mode = 2, .fg = 2, .bg = 2 },
        .{ .u = '丙', .mode = 3, .fg = 3, .bg = 3 },
        .{ .u = '丁', .mode = 4, .fg = 4, .bg = 4 },
    };
    const attr = ZigGlyph{ .u = 0, .mode = 7, .fg = 9, .bg = 8 };
    var dirty: c_int = 0;

    const result = st_tputcwrite('A', 1, &attr, &line, &dirty, 1, 4, 1, 1);

    try std.testing.expectEqual(@as(u32, 'A'), line[1].u);
    try std.testing.expectEqual(@as(u32, '乙'), line[2].u);
    try std.testing.expectEqual(@as(u32, '丙'), line[3].u);
    try std.testing.expectEqual(@as(c_int, putc_advance_move), result.advance);
    try std.testing.expectEqual(@as(c_int, 2), result.next_x);
}

test "tputcwrite marks wide and dummy" {
    var line = [_]ZigGlyph{
        .{ .u = 0, .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = 0, .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = 0, .mode = 0, .fg = 0, .bg = 0 },
    };
    const attr = ZigGlyph{ .u = 0, .mode = 5, .fg = 7, .bg = 6 };
    var dirty: c_int = 0;

    const result = st_tputcwrite('中', 2, &attr, &line, &dirty, 0, 3, 1, 0);

    try std.testing.expectEqual(@as(c_ushort, 5 | attr_wide), line[0].mode);
    try std.testing.expectEqual(@as(u32, 0), line[1].u);
    try std.testing.expectEqual(@as(c_ushort, attr_wdummy), line[1].mode);
    try std.testing.expectEqual(@as(c_int, putc_advance_move), result.advance);
    try std.testing.expectEqual(@as(c_int, 2), result.next_x);
}

test "tputcwrite wraps at right edge" {
    var line = [_]ZigGlyph{
        .{ .u = 0, .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = 0, .mode = 0, .fg = 0, .bg = 0 },
    };
    const attr = ZigGlyph{ .u = 0, .mode = 1, .fg = 1, .bg = 1 };
    var dirty: c_int = 0;

    const result = st_tputcwrite('A', 1, &attr, &line, &dirty, 1, 2, 1, 0);

    try std.testing.expectEqual(@as(c_int, putc_advance_wrapnext), result.advance);
    try std.testing.expectEqual(@as(c_int, 2), result.next_x);
}

test "tputcprepare combines current flags" {
    const plan = st_tputcprepare(1, 1, cursor_wrapnext, 9, 2, 10);
    try std.testing.expectEqual(@as(c_int, 1), plan.clear_selection);
    try std.testing.expectEqual(@as(c_int, 1), plan.wrapnext);
    try std.testing.expectEqual(@as(c_int, 1), plan.overflow);
}

test "tputcprepare skips flags when conditions fail" {
    const plan = st_tputcprepare(0, 0, 0, 3, 1, 10);
    try std.testing.expectEqual(@as(c_int, 0), plan.clear_selection);
    try std.testing.expectEqual(@as(c_int, 0), plan.wrapnext);
    try std.testing.expectEqual(@as(c_int, 0), plan.overflow);
}

test "tcollectstr appends chunk bytes" {
    var buf = [_]u8{ 0, 0, 0, 0, 0, 0 };
    const chunk = [_]u8{ 'A', 'B' };

    const exec = st_tcollectstr('A', esc_start | esc_str, &buf, 1, &chunk, chunk.len, buf.len);

    try std.testing.expectEqual(@as(usize, 3), exec.new_len);
    try std.testing.expectEqual(@as(u8, 'A'), buf[1]);
    try std.testing.expectEqual(@as(u8, 'B'), buf[2]);
}

test "tcollectstr finish updates esc bits" {
    var buf = [_]u8{ 0, 0, 0, 0 };
    const chunk = [_]u8{'A'};

    const exec = st_tcollectstr(0x07, esc_start | esc_str, &buf, 0, &chunk, 0, buf.len);

    try std.testing.expectEqual(@as(c_int, esc_str_end), exec.new_esc);
    try std.testing.expectEqual(@as(usize, 0), exec.new_len);
}

test "tcollectstr requests growth without appending" {
    var buf = [_]u8{ 0, 0, 0, 0 };
    const chunk = [_]u8{'A'};

    const exec = st_tcollectstr('A', esc_start | esc_str, &buf, 3, &chunk, chunk.len, buf.len);

    try std.testing.expectEqual(@as(c_int, str_collect_grow), exec.kind);
    try std.testing.expectEqual(@as(usize, 8), exec.new_size);
    try std.testing.expectEqual(@as(usize, 3), exec.new_len);
}

test "tcollectstr appends chunk after planning" {
    var buf = [_]u8{ 0, 0, 0, 0 };
    const chunk = [_]u8{'X'};

    const exec = st_tcollectstr('A', esc_start | esc_str, &buf, 1, &chunk, chunk.len, buf.len);

    try std.testing.expectEqual(@as(c_int, str_collect_append), exec.kind);
    try std.testing.expectEqual(@as(u8, 'X'), buf[1]);
    try std.testing.expectEqual(@as(usize, 2), exec.new_len);
}

test "tescflow appends csi byte and finishes on final byte" {
    var buf = [_]u8{ 0, 0, 0, 0 };

    const exec = st_tescflow(esc_start | esc_csi, 'm', &buf, 0, buf.len);

    try std.testing.expectEqual(@as(c_int, esc_flow_csi), exec.kind);
    try std.testing.expectEqual(@as(c_int, 1), exec.handle_csi);
    try std.testing.expectEqual(@as(usize, 1), exec.new_csi_len);
    try std.testing.expectEqual(@as(u8, 'm'), buf[0]);
}

test "tescflow routes utf8 state" {
    var buf = [_]u8{ 0, 0 };

    const exec = st_tescflow(esc_start | esc_utf8, 'G', &buf, 0, buf.len);

    try std.testing.expectEqual(@as(c_int, esc_flow_utf8), exec.kind);
    try std.testing.expectEqual(@as(usize, 0), exec.new_csi_len);
}

test "tcontrolafter clears lastc only when esc is empty" {
    try std.testing.expectEqual(@as(c_int, 1), st_tcontrolafter(0));
    try std.testing.expectEqual(@as(c_int, 0), st_tcontrolafter(esc_start));
}

test "tescflowafter preserves esc when eschandle wants more" {
    const after = st_tescflowafter(esc_flow_esc, 0);
    try std.testing.expectEqual(@as(c_int, 0), after.clear_esc);
    try std.testing.expectEqual(@as(c_int, 0), after.new_esc);
    try std.testing.expectEqual(@as(c_int, 1), after.stop);
}

test "tescflowafter preserves esc while csi is collecting" {
    const after = st_tescflowafter(esc_flow_csi, 0);
    try std.testing.expectEqual(@as(c_int, 0), after.clear_esc);
    try std.testing.expectEqual(@as(c_int, 0), after.new_esc);
    try std.testing.expectEqual(@as(c_int, 1), after.stop);
}

test "tescflowafter clears esc after handled sequence" {
    const after = st_tescflowafter(esc_flow_utf8, 1);
    try std.testing.expectEqual(@as(c_int, 1), after.clear_esc);
    try std.testing.expectEqual(@as(c_int, 0), after.new_esc);
    try std.testing.expectEqual(@as(c_int, 1), after.stop);
}

test "esc planner enters csi mode" {
    const plan = planEsc('[');
    try std.testing.expectEqual(@as(c_int, esc_set_csi), plan.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.ret);
}

test "esc planner starts string sequence" {
    const plan = planEsc(']');
    try std.testing.expectEqual(@as(c_int, esc_start_str), plan.kind);
    try std.testing.expectEqual(@as(c_int, ']'), plan.value);
    try std.testing.expectEqual(@as(c_int, 0), plan.ret);
}

test "esc planner selects alt charset slot" {
    const plan = planEsc('+');
    try std.testing.expectEqual(@as(c_int, esc_set_altcharset), plan.kind);
    try std.testing.expectEqual(@as(c_int, 3), plan.value);
}

test "tescexec sets csi bit" {
    var esc: c_int = esc_start;
    var charset: c_int = 0;
    var icharset: c_int = 0;
    var tabs = [_]c_int{0};

    const exec = st_tescexec('[', &esc, &charset, &icharset, &tabs, 0);

    try std.testing.expectEqual(@as(c_int, esc_start | esc_csi), esc);
    try std.testing.expectEqual(@as(c_int, esc_action_none), exec.action);
    try std.testing.expectEqual(@as(c_int, 0), exec.ret);
}

test "tescexec selects alt charset and returns no action" {
    var esc: c_int = esc_start;
    var charset: c_int = 0;
    var icharset: c_int = 0;
    var tabs = [_]c_int{0};

    const exec = st_tescexec('+', &esc, &charset, &icharset, &tabs, 0);

    try std.testing.expectEqual(@as(c_int, 3), icharset);
    try std.testing.expectEqual(@as(c_int, esc_start | esc_altcharset), esc);
    try std.testing.expectEqual(@as(c_int, esc_action_none), exec.action);
}

test "tescexec maps index to action" {
    var esc: c_int = esc_start;
    var charset: c_int = 0;
    var icharset: c_int = 0;
    var tabs = [_]c_int{0};

    const exec = st_tescexec('D', &esc, &charset, &icharset, &tabs, 0);

    try std.testing.expectEqual(@as(c_int, esc_action_ind), exec.action);
    try std.testing.expectEqual(@as(c_int, 1), exec.ret);
}

test "controlexec escape updates esc bits" {
    var esc: c_int = esc_csi | esc_altcharset | esc_test;
    var charset: c_int = 0;
    var tabs = [_]c_int{0};

    const exec = st_tcontrolexec('\x1b', &esc, &charset, &tabs, 0);

    try std.testing.expectEqual(@as(c_int, esc_start), esc);
    try std.testing.expectEqual(@as(c_int, ctl_action_escape), exec.action);
    try std.testing.expectEqual(@as(c_int, 0), exec.clear_str);
}

test "controlexec lock shift updates charset" {
    var esc: c_int = 0;
    var charset: c_int = 0;
    var tabs = [_]c_int{0};

    const exec = st_tcontrolexec('\x0e', &esc, &charset, &tabs, 0);

    try std.testing.expectEqual(@as(c_int, 1), charset);
    try std.testing.expectEqual(@as(c_int, ctl_action_none), exec.action);
}

test "controlexec sets tab stop and clears string" {
    var esc: c_int = 0;
    var charset: c_int = 0;
    var tabs = [_]c_int{ 0, 0 };

    const exec = st_tcontrolexec(0x88, &esc, &charset, &tabs, 1);

    try std.testing.expectEqual(@as(c_int, 1), tabs[1]);
    try std.testing.expectEqual(@as(c_int, 1), exec.clear_str);
}
