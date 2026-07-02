//! st_setchar.zig 是当前最厚的 Zig 迁移模块，承载字符写入、STR 收集、ESC/control 输入计划等核心逻辑。
//! [输入]: C 侧传入 rune、glyph 属性、当前行 buffer、ESC 状态、CSI/STR 缓冲区和必要的光标/终端尺寸字段。
//! [输出]: 通过 extern struct 返回写入结果、prepare plan、STR collect 结果、ESC/control/input flow plan。
//! [副作用边界]: 可修改传入的局部 glyph 行和显式传入的状态指针；不直接调用 X11、tty、滚屏、selection、allocator 或全局 `term`。
//! [定位]: 这是 `tsetchar(...)` 与 `tputc(...)` 逐步迁移的汇聚点，目标是在不扩大 C/Zig 全局状态耦合的前提下持续压薄 `st.c`。

const std = @import("std");
const control_esc = @import("st_control_esc.zig");
const term_update = @import("st_term_update.zig");

pub const ZigGlyph = extern struct {
    u: u32,
    mode: c_ushort,
    fg: u32,
    bg: u32,
};

pub const ZigPutcWriteResult = extern struct {
    advance: c_int,
    next_x: c_int,
    cursor_state_mask: c_int,
    cursor_state_bits: c_int,
};

pub const ZigPutcPreparePlan = extern struct {
    clear_selection: c_int,
    wrapnext: c_int,
    overflow: c_int,
};

pub const ZigPutcStepPlan = extern struct {
    clear_selection: c_int,
    wrapnext_newline: c_int,
    overflow_newline: c_int,
    write_glyph: c_int,
    mark_dirty: c_int,
    advance: c_int,
    next_x: c_int,
    cursor_state_mask: c_int,
    cursor_state_bits: c_int,
};

pub const ZigStrCollectExec = extern struct {
    kind: c_int,
    new_esc: c_int,
    new_len: usize,
    new_size: usize,
};

pub const ZigStrCollectApplyPlan = extern struct {
    first: ZigStrCollectExec,
    retry: c_int,
};

pub const ZigStrCollectStep = extern struct {
    kind: c_int,
    exec: ZigStrCollectExec,
};

pub const ZigStrCollectTransaction = extern struct {
    step_count: c_int,
    steps: [4]ZigStrCollectStep,
};

pub const ZigStrResetPlan = extern struct {
    size: usize,
};

pub const ZigInputEscFlowPlan = extern struct {
    kind: c_int,
    action_count: c_int,
    actions: [3]c_int,
    handle_csi: c_int,
    csi_write: c_int,
    csi_byte: u8,
    new_csi_len: usize,
    finish_esc: c_int,
};

pub const ZigInputScalarStateUpdate = extern struct {
    esc: c_int,
    charset_set: c_int,
    charset: c_int,
    icharset_set: c_int,
    icharset: c_int,
    tab_set: c_int,
    tab_x: c_int,
    term_update: term_update.ZigTermStateUpdate,
};

pub const ZigInputControlPlan = extern struct {
    action: c_int,
    finish_esc: c_int,
    state: ZigInputScalarStateUpdate,
};

pub const ZigInputEscPlan = extern struct {
    action: c_int,
    ret: c_int,
    state: ZigInputScalarStateUpdate,
};

pub const ZigInputRoutingPlan = extern struct {
    is_str: c_int,
    is_control: c_int,
    is_esc: c_int,
};

pub const ZigInputStepPlan = extern struct {
    route: c_int,
    print: c_int,
    routing: ZigInputRoutingPlan,
    collect: ZigStrCollectTransaction,
    control: ZigInputControlPlan,
    esc_flow: ZigInputEscFlowPlan,
    putc: ZigPutcStepPlan,
};

pub const ZigEscPlan = control_esc.ZigEscPlan;

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
const str_collect_step_apply_first = 1;
const str_collect_step_grow_buffer = 2;
const str_collect_step_retry_collect = 3;
const str_collect_step_finish = 4;
const str_collect_step_abort = 5;
const str_buf_size: usize = 128 * 4;

comptime {
    std.debug.assert(str_buf_size == 512);
}
const esc_start = control_esc.esc_start;
const esc_csi = control_esc.esc_csi;
const esc_altcharset = control_esc.esc_altcharset;
const esc_test = control_esc.esc_test;
const esc_utf8 = control_esc.esc_utf8;
const esc_str = control_esc.esc_str;
const esc_str_end = control_esc.esc_str_end;
// `esc_flow_*` 是 `EscFlow` 返回给 C executor 的本地流程分类，不属于共享 ESC 状态位。
const esc_flow_none = 0;
const esc_flow_csi = 1;
const esc_flow_utf8 = 2;
const esc_flow_altcharset = 3;
const esc_flow_test = 4;
const esc_flow_esc = 5;
const esc_flow_action_write_csi_byte = 1;
const esc_flow_action_parse_csi = 2;
const esc_flow_action_handle_csi = 3;
const esc_flow_action_define_utf8 = 4;
const esc_flow_action_define_charset = 5;
const esc_flow_action_dec_test = 6;
const esc_flow_action_esc_handle = 7;
const esc_set_csi = control_esc.esc_set_csi;
const esc_start_str = control_esc.esc_start_str;
const esc_set_altcharset = control_esc.esc_set_altcharset;
const esc_action_none = control_esc.esc_action_none;
const esc_action_ind = control_esc.esc_action_ind;
const ctl_action_none = control_esc.ctl_action_none;
const ctl_action_escape = control_esc.ctl_action_escape;
const input_route_graphic = 0;
const input_route_str = 1;
const input_route_control = 2;
const input_route_esc = 3;

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

const GlyphLine = struct {
    line: [*]ZigGlyph,
    col: c_int,
    trantbl: c_int,

    fn setChar(self: GlyphLine, rune: u32, attr: *const ZigGlyph, x: c_int) void {
        const next_rune = self.translateRune(rune);
        const current_mode = self.line[@intCast(x)].mode;

        if ((current_mode & attr_wide) != 0 and x + 1 < self.col) {
            self.line[@intCast(x + 1)].u = ' ';
            self.line[@intCast(x + 1)].mode &= ~attr_wdummy;
        } else if ((current_mode & attr_wdummy) != 0 and x > 0) {
            self.line[@intCast(x - 1)].u = ' ';
            self.line[@intCast(x - 1)].mode &= ~attr_wide;
        }

        self.line[@intCast(x)] = attr.*;
        self.line[@intCast(x)].u = next_rune;
    }

    fn clearGlyph(self: GlyphLine, x: c_int, attr: *const ZigGlyph) void {
        self.line[@intCast(x)].fg = attr.fg;
        self.line[@intCast(x)].bg = attr.bg;
        self.line[@intCast(x)].mode = 0;
        self.line[@intCast(x)].u = ' ';
    }

    fn putcWrite(self: GlyphLine, rune: u32, width: c_int, attr: *const ZigGlyph, x: c_int, insert_mode: bool) ZigPutcWriteResult {
        if (insert_mode and x + width < self.col) {
            self.shiftRight(x, width);
        }

        self.setChar(rune, attr, x);

        if (width == 2) {
            self.line[@intCast(x)].mode |= attr_wide;
            if (x + 1 < self.col) {
                self.line[@intCast(x + 1)].u = 0;
                self.line[@intCast(x + 1)].mode = attr_wdummy;
            }
        }

        return .{
            .advance = if (x + width < self.col) putc_advance_move else putc_advance_wrapnext,
            .next_x = x + width,
            .cursor_state_mask = if (x + width < self.col) 0 else cursor_wrapnext,
            .cursor_state_bits = if (x + width < self.col) 0 else cursor_wrapnext,
        };
    }

    fn shiftRight(self: GlyphLine, x: c_int, width: c_int) void {
        const move_count: usize = @intCast(self.col - x - width);
        const base_x: usize = @intCast(x);
        const gap: usize = @intCast(width);

        var i = move_count;
        while (i > 0) {
            i -= 1;
            self.line[base_x + gap + i] = self.line[base_x + i];
        }
    }

    fn translateRune(self: GlyphLine, rune: u32) u32 {
        if (self.trantbl == cs_graphic0 and 0x41 <= rune and rune <= 0x7E) {
            const mapped = graphic0_map[rune - 0x41];
            if (mapped != 0) {
                return mapped;
            }
        }

        return rune;
    }
};

const PutcPrepare = struct {
    selected_current: bool,
    mode_wrap: bool,
    cursor_state: c_int,
    x: c_int,
    width: c_int,
    col: c_int,

    fn plan(self: PutcPrepare) ZigPutcPreparePlan {
        return .{
            .clear_selection = if (self.selected_current) 1 else 0,
            .wrapnext = if (self.mode_wrap and (self.cursor_state & cursor_wrapnext) != 0) 1 else 0,
            .overflow = if (self.x + self.width > self.col) 1 else 0,
        };
    }
};

const PutcStep = struct {
    selected_current: bool,
    mode_wrap: bool,
    cursor_state: c_int,
    x: c_int,
    width: c_int,
    col: c_int,

    fn plan(self: PutcStep) ZigPutcStepPlan {
        const prepare = (PutcPrepare{ .selected_current = self.selected_current, .mode_wrap = self.mode_wrap, .cursor_state = self.cursor_state, .x = self.x, .width = self.width, .col = self.col }).plan();
        return .{
            .clear_selection = prepare.clear_selection,
            .wrapnext_newline = prepare.wrapnext,
            .overflow_newline = prepare.overflow,
            .write_glyph = 1,
            .mark_dirty = 1,
            .advance = if (self.x + self.width < self.col) putc_advance_move else putc_advance_wrapnext,
            .next_x = self.x + self.width,
            .cursor_state_mask = if (self.x + self.width < self.col) 0 else cursor_wrapnext,
            .cursor_state_bits = if (self.x + self.width < self.col) 0 else cursor_wrapnext,
        };
    }
};

const StringCollector = struct {
    rune: u32,
    esc: c_int,
    buf: [*]u8,
    len: usize,
    chunk: [*]const u8,
    chunk_len: usize,
    size: usize,

    fn exec(self: StringCollector) ZigStrCollectExec {
        const next = self.plan();

        if (next.kind == str_collect_finish) {
            return .{
                .kind = next.kind,
                .new_esc = (self.esc & ~(esc_start | esc_str)) | esc_str_end,
                .new_len = self.len,
                .new_size = self.size,
            };
        }

        if (next.kind == str_collect_abort) {
            return .{
                .kind = next.kind,
                .new_esc = self.esc,
                .new_len = self.len,
                .new_size = self.size,
            };
        }

        if (next.kind == str_collect_grow) {
            return .{
                .kind = next.kind,
                .new_esc = self.esc,
                .new_len = self.len,
                .new_size = next.new_size,
            };
        }

        @memcpy(self.buf[self.len .. self.len + @as(usize, @intCast(self.chunk_len))], self.chunk[0..@intCast(self.chunk_len)]);
        return .{
            .kind = next.kind,
            .new_esc = self.esc,
            .new_len = self.len + @as(usize, @intCast(self.chunk_len)),
            .new_size = self.size,
        };
    }

    fn plan(self: StringCollector) ZigStrCollectExec {
        if (self.terminates()) {
            return .{ .kind = str_collect_finish, .new_esc = 0, .new_len = self.len, .new_size = self.size };
        }

        if (self.len + self.chunk_len >= self.size) {
            if (self.size > (std.math.maxInt(usize) - 4) / 2) {
                return .{ .kind = str_collect_abort, .new_esc = 0, .new_len = self.len, .new_size = self.size };
            }
            return .{ .kind = str_collect_grow, .new_esc = 0, .new_len = self.len, .new_size = self.size * 2 };
        }

        return .{ .kind = str_collect_append, .new_esc = 0, .new_len = self.len, .new_size = self.size };
    }

    fn terminates(self: StringCollector) bool {
        return self.rune == 0x07 or self.rune == 0x18 or self.rune == 0x1A or self.rune == 0x1B or (0x80 <= self.rune and self.rune <= 0x9F);
    }
};

const EscFlow = struct {
    esc: c_int,
    rune: u32,
    csi_buf: [*]u8,
    csi_len: usize,
    csi_cap: usize,

    fn exec(self: EscFlow) ZigInputEscFlowPlan {
        if ((self.esc & esc_csi) != 0) {
            const new_len = self.csi_len + 1;
            const handle_csi: c_int = if ((0x40 <= self.rune and self.rune <= 0x7E) or self.csi_len >= self.csi_cap - 1) 1 else 0;
            var plan = escFlow(esc_flow_csi, 1, @truncate(self.rune), new_len, 0);
            plan.handle_csi = handle_csi;
            addEscFlowAction(&plan, esc_flow_action_write_csi_byte);
            if (handle_csi != 0) {
                addEscFlowAction(&plan, esc_flow_action_parse_csi);
                addEscFlowAction(&plan, esc_flow_action_handle_csi);
            }
            return plan;
        }
        if ((self.esc & esc_utf8) != 0) return escFlowWithAction(esc_flow_utf8, self.csi_len, esc_flow_action_define_utf8);
        if ((self.esc & esc_altcharset) != 0) return escFlowWithAction(esc_flow_altcharset, self.csi_len, esc_flow_action_define_charset);
        if ((self.esc & esc_test) != 0) return escFlowWithAction(esc_flow_test, self.csi_len, esc_flow_action_dec_test);
        if ((self.esc & esc_start) != 0) return escFlowWithAction(esc_flow_esc, self.csi_len, esc_flow_action_esc_handle);
        return emptyEscFlow(esc_flow_none, self.csi_len);
    }
};

fn emptyEscFlow(kind: c_int, csi_len: usize) ZigInputEscFlowPlan {
    return escFlow(kind, 0, 0, csi_len, 0);
}

fn escFlow(kind: c_int, csi_write: c_int, csi_byte: u8, csi_len: usize, finish_esc: c_int) ZigInputEscFlowPlan {
    return .{ .kind = kind, .action_count = 0, .actions = .{ 0, 0, 0 }, .handle_csi = 0, .csi_write = csi_write, .csi_byte = csi_byte, .new_csi_len = csi_len, .finish_esc = finish_esc };
}

fn escFlowWithAction(kind: c_int, csi_len: usize, action: c_int) ZigInputEscFlowPlan {
    var plan = escFlow(kind, 0, 0, csi_len, 0);
    addEscFlowAction(&plan, action);
    return plan;
}

fn addEscFlowAction(plan: *ZigInputEscFlowPlan, action: c_int) void {
    if (@as(usize, @intCast(plan.action_count)) >= plan.actions.len) return;
    plan.actions[@intCast(plan.action_count)] = action;
    plan.action_count += 1;
}

export fn st_tsetchar(rune: u32, attr: *const ZigGlyph, line: [*]ZigGlyph, x: c_int, col: c_int, trantbl: c_int) void {
    (GlyphLine{ .line = line, .col = col, .trantbl = trantbl }).setChar(rune, attr, x);
}

export fn st_tclearglyph(line: [*]ZigGlyph, x: c_int, attr: *const ZigGlyph) void {
    (GlyphLine{ .line = line, .col = x + 1, .trantbl = 0 }).clearGlyph(x, attr);
}

export fn st_tputcwrite(rune: u32, width: c_int, attr: *const ZigGlyph, line: [*]ZigGlyph, x: c_int, col: c_int, trantbl: c_int, insert_mode: c_int) ZigPutcWriteResult {
    return (GlyphLine{ .line = line, .col = col, .trantbl = trantbl }).putcWrite(rune, width, attr, x, insert_mode != 0);
}

fn st_tputcstepplan(selected_current: c_int, mode_wrap: c_int, cursor_state: c_int, x: c_int, width: c_int, col: c_int) ZigPutcStepPlan {
    return (PutcStep{ .selected_current = selected_current != 0, .mode_wrap = mode_wrap != 0, .cursor_state = cursor_state, .x = x, .width = width, .col = col }).plan();
}

fn inputRoutingPlan(esc: c_int, control: c_int) ZigInputRoutingPlan {
    return .{
        .is_str = if ((esc & esc_str) != 0) 1 else 0,
        .is_control = if (control != 0) 1 else 0,
        .is_esc = if ((esc & esc_start) != 0) 1 else 0,
    };
}

export fn st_inputstepplan(esc: c_int, control: c_int, print_mode: c_int, rune: u32, buf: [*]u8, str_len: usize, chunk: [*]const u8, chunk_len: usize, str_size: usize, csi_len: usize, csi_cap: usize, charset: c_int, cursor_x: c_int, icharset: c_int, selected_current: c_int, mode_wrap: c_int, cursor_state: c_int, width: c_int, col: c_int) ZigInputStepPlan {
    const routing = inputRoutingPlan(esc, control);
    const control_byte: u8 = if (control != 0) @truncate(rune) else 0;
    _ = icharset;
    return .{
        .route = if (routing.is_str != 0) input_route_str else if (routing.is_control != 0) input_route_control else if (routing.is_esc != 0) input_route_esc else input_route_graphic,
        .print = if (print_mode != 0) 1 else 0,
        .routing = routing,
        .collect = st_strcollecttransaction(rune, esc, buf, str_len, chunk, chunk_len, str_size),
        .control = st_inputcontrolplan(control_byte, esc, charset, cursor_x),
        .esc_flow = st_inputescflowplan(esc, rune, csi_len, csi_cap),
        .putc = st_tputcstepplan(selected_current, mode_wrap, cursor_state, cursor_x, width, col),
    };
}

fn st_tcollectstr(rune: u32, esc: c_int, buf: [*]u8, len: usize, chunk: [*]const u8, chunk_len: usize, size: usize) ZigStrCollectExec {
    return (StringCollector{ .rune = rune, .esc = esc, .buf = buf, .len = len, .chunk = chunk, .chunk_len = chunk_len, .size = size }).exec();
}

fn retryCollectExec(rune: u32, esc: c_int, len: usize, chunk_len: usize, size: usize) ZigStrCollectExec {
    const retry = (StringCollector{ .rune = rune, .esc = esc, .buf = undefined, .len = len, .chunk = undefined, .chunk_len = chunk_len, .size = size }).plan();
    return switch (retry.kind) {
        str_collect_append => .{ .kind = str_collect_append, .new_esc = esc, .new_len = len + chunk_len, .new_size = size },
        str_collect_finish => .{ .kind = str_collect_finish, .new_esc = (esc & ~(esc_start | esc_str)) | esc_str_end, .new_len = len, .new_size = size },
        str_collect_abort => .{ .kind = str_collect_abort, .new_esc = esc, .new_len = len, .new_size = size },
        else => .{ .kind = str_collect_abort, .new_esc = esc, .new_len = len, .new_size = size },
    };
}

fn collectStrApply(rune: u32, esc: c_int, buf: [*]u8, len: usize, chunk: [*]const u8, chunk_len: usize, size: usize) ZigStrCollectApplyPlan {
    const first = st_tcollectstr(rune, esc, buf, len, chunk, chunk_len, size);
    return .{ .first = first, .retry = if (first.kind == str_collect_grow) 1 else 0 };
}

fn st_strcollecttransaction(rune: u32, esc: c_int, buf: [*]u8, len: usize, chunk: [*]const u8, chunk_len: usize, size: usize) ZigStrCollectTransaction {
    const plan = collectStrApply(rune, esc, buf, len, chunk, chunk_len, size);
    var tx = ZigStrCollectTransaction{ .step_count = 1, .steps = std.mem.zeroes([4]ZigStrCollectStep) };
    switch (plan.first.kind) {
        str_collect_finish => tx.steps[0] = .{ .kind = str_collect_step_finish, .exec = plan.first },
        str_collect_abort => tx.steps[0] = .{ .kind = str_collect_step_abort, .exec = plan.first },
        str_collect_grow => {
            tx.steps[0] = .{ .kind = str_collect_step_grow_buffer, .exec = plan.first };
            tx.steps[1] = .{ .kind = str_collect_step_retry_collect, .exec = retryCollectExec(rune, esc, len, chunk_len, plan.first.new_size) };
            tx.step_count = 2;
        },
        else => tx.steps[0] = .{ .kind = str_collect_step_apply_first, .exec = plan.first },
    }
    if (plan.retry != 0 and plan.first.kind != str_collect_grow) {
        tx.steps[1] = .{ .kind = str_collect_step_retry_collect, .exec = retryCollectExec(rune, esc, len, chunk_len, plan.first.new_size) };
        tx.step_count = 2;
    }
    return tx;
}

export fn st_strresetplan() ZigStrResetPlan {
    return .{ .size = str_buf_size };
}

fn st_inputescflowplan(esc: c_int, rune: u32, csi_len: usize, csi_cap: usize) ZigInputEscFlowPlan {
    return (EscFlow{ .esc = esc, .rune = rune, .csi_buf = undefined, .csi_len = csi_len, .csi_cap = csi_cap }).exec();
}

fn planEsc(ascii: u8) ZigEscPlan {
    return (control_esc.EscSequence{ .ascii = ascii }).plan();
}

export fn st_inputescplan(ascii: u8, esc: c_int, charset: c_int, icharset: c_int, x: c_int) ZigInputEscPlan {
    const raw = (control_esc.EscSequence{ .ascii = ascii }).plan();
    var new_esc = esc;
    var charset_set: c_int = 0;
    var next_charset = charset;
    var icharset_set: c_int = 0;
    var next_icharset = icharset;
    var tab_set: c_int = 0;
    switch (raw.kind) {
        esc_set_csi => new_esc = esc | esc_csi,
        control_esc.esc_set_test => new_esc = esc | esc_test,
        control_esc.esc_set_utf8 => new_esc = esc | esc_utf8,
        control_esc.esc_lock_shift => {
            charset_set = 1;
            next_charset = raw.value;
        },
        esc_set_altcharset => {
            icharset_set = 1;
            next_icharset = raw.value;
            new_esc = esc | esc_altcharset;
        },
        control_esc.esc_hts => tab_set = 1,
        else => {},
    }
    return .{
        .action = control_esc.EscSequence.action(raw.kind),
        .ret = raw.ret,
        .state = inputState(new_esc, charset_set, next_charset, icharset_set, next_icharset, tab_set, x),
    };
}

export fn st_inputcontrolplan(ascii: u8, esc: c_int, charset: c_int, x: c_int) ZigInputControlPlan {
    const raw = (control_esc.ControlSequence{ .ascii = ascii }).plan();
    var new_esc = esc;
    var finish_esc = esc;
    var charset_set: c_int = 0;
    var next_charset = charset;
    var tab_set: c_int = 0;
    switch (raw.kind) {
        control_esc.ctl_escape => {
            new_esc = (esc & ~(esc_csi | esc_altcharset | esc_test)) | esc_start;
            finish_esc = new_esc;
        },
        control_esc.ctl_lock_shift => {
            charset_set = 1;
            next_charset = raw.value;
        },
        control_esc.ctl_set_tab_stop => tab_set = 1,
        else => {},
    }
    if (control_esc.ControlSequence.clearsString(raw.kind)) {
        finish_esc = new_esc & ~(esc_str_end | esc_str);
    }
    return .{
        .action = control_esc.ControlSequence.action(raw.kind),
        .finish_esc = finish_esc,
        .state = inputState(new_esc, charset_set, next_charset, 0, 0, tab_set, x),
    };
}

fn inputState(esc: c_int, charset_set: c_int, charset: c_int, icharset_set: c_int, icharset: c_int, tab_set: c_int, tab_x: c_int) ZigInputScalarStateUpdate {
    var update = std.mem.zeroes(term_update.ZigTermStateUpdate);
    if (charset_set != 0) {
        update.set_charset = 1;
        update.charset = charset;
    }
    return .{ .esc = esc, .charset_set = charset_set, .charset = charset, .icharset_set = icharset_set, .icharset = icharset, .tab_set = tab_set, .tab_x = tab_x, .term_update = update };
}

fn controlAction(kind: c_int) c_int {
    return control_esc.ControlSequence.action(kind);
}

fn clearsString(kind: c_int) bool {
    return control_esc.ControlSequence.clearsString(kind);
}

fn escAction(kind: c_int) c_int {
    return control_esc.EscSequence.action(kind);
}

fn translateRune(rune: u32, trantbl: c_int) u32 {
    return (GlyphLine{ .line = undefined, .col = 0, .trantbl = trantbl }).translateRune(rune);
}

fn shiftRight(line: [*]ZigGlyph, x: c_int, width: c_int, col: c_int) void {
    (GlyphLine{ .line = line, .col = col, .trantbl = 0 }).shiftRight(x, width);
}

fn planStrCollect(rune: u32, current_len: usize, chunk_len: usize, current_size: usize) ZigStrCollectExec {
    return (StringCollector{ .rune = rune, .esc = 0, .buf = undefined, .len = current_len, .chunk = undefined, .chunk_len = chunk_len, .size = current_size }).plan();
}

fn terminatesString(rune: u32) bool {
    return (StringCollector{ .rune = rune, .esc = 0, .buf = undefined, .len = 0, .chunk = undefined, .chunk_len = 0, .size = 0 }).terminates();
}

test "tsetchar writes translated graphic rune" {
    var line = [_]ZigGlyph{
        .{ .u = 0, .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = 0, .mode = 0, .fg = 0, .bg = 0 },
    };
    const attr = ZigGlyph{ .u = 0, .mode = 7, .fg = 1, .bg = 2 };

    st_tsetchar('q', &attr, &line, 0, 2, cs_graphic0);

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

    st_tsetchar('A', &attr, &line, 0, 3, 1);

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

    st_tsetchar('B', &attr, &line, 1, 3, 1);

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

    const result = st_tputcwrite('A', 1, &attr, &line, 1, 4, 1, 1);

    try std.testing.expectEqual(@as(u32, 'A'), line[1].u);
    try std.testing.expectEqual(@as(u32, '乙'), line[2].u);
    try std.testing.expectEqual(@as(u32, '丙'), line[3].u);
    try std.testing.expectEqual(@as(c_int, putc_advance_move), result.advance);
    try std.testing.expectEqual(@as(c_int, 2), result.next_x);
    try std.testing.expectEqual(@as(c_int, 0), result.cursor_state_mask);
    try std.testing.expectEqual(@as(c_int, 0), result.cursor_state_bits);
}

test "tputcwrite marks wide and dummy" {
    var line = [_]ZigGlyph{
        .{ .u = 0, .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = 0, .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = 0, .mode = 0, .fg = 0, .bg = 0 },
    };
    const attr = ZigGlyph{ .u = 0, .mode = 5, .fg = 7, .bg = 6 };

    const result = st_tputcwrite('中', 2, &attr, &line, 0, 3, 1, 0);

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

    const result = st_tputcwrite('A', 1, &attr, &line, 1, 2, 1, 0);

    try std.testing.expectEqual(@as(c_int, putc_advance_wrapnext), result.advance);
    try std.testing.expectEqual(@as(c_int, 2), result.next_x);
    try std.testing.expectEqual(@as(c_int, cursor_wrapnext), result.cursor_state_mask);
    try std.testing.expectEqual(@as(c_int, cursor_wrapnext), result.cursor_state_bits);
}

test "tputcwrite wide rune at edge does not write dummy past column" {
    var line = [_]ZigGlyph{
        .{ .u = 0, .mode = 0, .fg = 0, .bg = 0 },
        .{ .u = 0, .mode = 0, .fg = 0, .bg = 0 },
    };
    const attr = ZigGlyph{ .u = 0, .mode = 3, .fg = 1, .bg = 2 };

    const result = st_tputcwrite('界', 2, &attr, &line, 1, 2, 1, 0);

    try std.testing.expectEqual(@as(c_ushort, 3 | attr_wide), line[1].mode);
    try std.testing.expectEqual(@as(c_int, putc_advance_wrapnext), result.advance);
    try std.testing.expectEqual(@as(c_int, 3), result.next_x);
}

test "tputcprepare combines current flags" {
    const plan = (PutcPrepare{ .selected_current = true, .mode_wrap = true, .cursor_state = cursor_wrapnext, .x = 9, .width = 2, .col = 10 }).plan();
    try std.testing.expectEqual(@as(c_int, 1), plan.clear_selection);
    try std.testing.expectEqual(@as(c_int, 1), plan.wrapnext);
    try std.testing.expectEqual(@as(c_int, 1), plan.overflow);
}

test "tputcstep combines prepare write and advance" {
    const plan = st_tputcstepplan(1, 1, cursor_wrapnext, 9, 1, 10);

    try std.testing.expectEqual(@as(c_int, 1), plan.clear_selection);
    try std.testing.expectEqual(@as(c_int, 1), plan.wrapnext_newline);
    try std.testing.expectEqual(@as(c_int, 0), plan.overflow_newline);
    try std.testing.expectEqual(@as(c_int, 1), plan.write_glyph);
    try std.testing.expectEqual(@as(c_int, 1), plan.mark_dirty);
    try std.testing.expectEqual(@as(c_int, putc_advance_wrapnext), plan.advance);
    try std.testing.expectEqual(@as(c_int, 10), plan.next_x);
    try std.testing.expectEqual(@as(c_int, cursor_wrapnext), plan.cursor_state_mask);
    try std.testing.expectEqual(@as(c_int, cursor_wrapnext), plan.cursor_state_bits);
}

test "tputcprepare skips flags when conditions fail" {
    const plan = (PutcPrepare{ .selected_current = false, .mode_wrap = false, .cursor_state = 0, .x = 3, .width = 1, .col = 10 }).plan();
    try std.testing.expectEqual(@as(c_int, 0), plan.clear_selection);
    try std.testing.expectEqual(@as(c_int, 0), plan.wrapnext);
    try std.testing.expectEqual(@as(c_int, 0), plan.overflow);
}

test "input routing prioritizes string state" {
    const route = inputRoutingPlan(esc_start | esc_str, 1);

    try std.testing.expectEqual(@as(c_int, 1), route.is_str);
    try std.testing.expectEqual(@as(c_int, 1), route.is_control);
    try std.testing.expectEqual(@as(c_int, 1), route.is_esc);
}

test "input routing identifies graphic input" {
    const route = inputRoutingPlan(0, 0);

    try std.testing.expectEqual(@as(c_int, 0), route.is_str);
    try std.testing.expectEqual(@as(c_int, 0), route.is_control);
    try std.testing.expectEqual(@as(c_int, 0), route.is_esc);
}

test "input step returns route and print effect" {
    var buf = [_]u8{0} ** 8;
    const chunk = [_]u8{'A'};
    const str = st_inputstepplan(esc_start | esc_str, 1, 1, 'A', &buf, 0, &chunk, chunk.len, buf.len, 0, 8, 0, 0, 0, 0, 1, 0, 1, 8);
    const control = st_inputstepplan(0, 1, 0, '\x0e', &buf, 0, &chunk, chunk.len, buf.len, 0, 8, 0, 0, 0, 0, 1, 0, 1, 8);
    const esc = st_inputstepplan(esc_start, 0, 0, '[', &buf, 0, &chunk, chunk.len, buf.len, 0, 8, 0, 0, 0, 0, 1, 0, 1, 8);
    const graphic = st_inputstepplan(0, 0, 0, 'A', &buf, 0, &chunk, chunk.len, buf.len, 0, 8, 0, 0, 0, 0, 1, 0, 1, 8);

    try std.testing.expectEqual(@as(c_int, input_route_str), str.route);
    try std.testing.expectEqual(@as(c_int, 1), str.print);
    try std.testing.expectEqual(@as(c_int, str_collect_append), str.collect.steps[0].exec.kind);
    try std.testing.expectEqual(@as(c_int, input_route_control), control.route);
    try std.testing.expectEqual(@as(c_int, 1), control.control.state.charset_set);
    try std.testing.expectEqual(@as(c_int, input_route_esc), esc.route);
    try std.testing.expectEqual(@as(c_int, esc_flow_esc), esc.esc_flow.kind);
    try std.testing.expectEqual(@as(c_int, input_route_graphic), graphic.route);
    try std.testing.expectEqual(@as(c_int, putc_advance_move), graphic.putc.advance);
}

test "input step ignores non-control rune when building control subplan" {
    var buf = [_]u8{0} ** 8;
    const chunk = [_]u8{ 0xe4, 0xb8, 0xad };
    const step = st_inputstepplan(0, 0, 0, '中', &buf, 0, &chunk, chunk.len, buf.len, 0, 8, 0, 0, 0, 0, 1, 0, 2, 8);

    try std.testing.expectEqual(@as(c_int, input_route_graphic), step.route);
    try std.testing.expectEqual(@as(c_int, ctl_action_none), step.control.action);
}

test "input step keeps string terminator control action" {
    var buf = [_]u8{0} ** 8;
    const chunk = [_]u8{};
    const step = st_inputstepplan(esc_start | esc_str, 1, 0, 0x07, &buf, 0, &chunk, chunk.len, buf.len, 0, 8, 0, 0, 0, 0, 1, 0, 1, 8);

    try std.testing.expectEqual(@as(c_int, input_route_str), step.route);
    try std.testing.expectEqual(@as(c_int, str_collect_step_finish), step.collect.steps[0].kind);
    try std.testing.expectEqual(@as(c_int, control_esc.ctl_action_bell), step.control.action);
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

test "tcollectstr apply marks retry after growth" {
    var buf = [_]u8{ 0, 0, 0, 0 };
    const chunk = [_]u8{'A'};

    const plan = collectStrApply('A', esc_start | esc_str, &buf, 3, &chunk, chunk.len, buf.len);

    try std.testing.expectEqual(@as(c_int, str_collect_grow), plan.first.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.retry);
}

test "tcollectstr apply skips retry after append" {
    var buf = [_]u8{ 0, 0, 0, 0 };
    const chunk = [_]u8{'A'};

    const plan = collectStrApply('A', esc_start | esc_str, &buf, 1, &chunk, chunk.len, buf.len);

    try std.testing.expectEqual(@as(c_int, str_collect_append), plan.first.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.retry);
}

test "tcollectstr apply retry cycle appends after growth" {
    var buf = [_]u8{ 0, 0, 0, 0 };
    const chunk = [_]u8{'A'};
    const plan = collectStrApply('A', esc_start | esc_str, &buf, 3, &chunk, chunk.len, buf.len);

    var grown = [_]u8{0} ** 8;
    @memcpy(grown[0..3], buf[0..3]);
    const retry = st_tcollectstr('A', esc_start | esc_str, &grown, 3, &chunk, chunk.len, grown.len);

    try std.testing.expectEqual(@as(c_int, str_collect_grow), plan.first.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.retry);
    try std.testing.expectEqual(@as(c_int, str_collect_append), retry.kind);
    try std.testing.expectEqual(@as(usize, 4), retry.new_len);
    try std.testing.expectEqual(@as(u8, 'A'), grown[3]);
}

test "tcollectstr apply skips retry after finish" {
    var buf = [_]u8{ 0, 0, 0, 0 };
    const chunk = [_]u8{};

    const plan = collectStrApply(0x07, esc_start | esc_str, &buf, 0, &chunk, chunk.len, buf.len);

    try std.testing.expectEqual(@as(c_int, str_collect_finish), plan.first.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.retry);
}

test "tcollectstr apply skips retry after abort" {
    var buf = [_]u8{0};
    const chunk = [_]u8{'A'};
    const near_limit = (std.math.maxInt(usize) - 4) / 2 + 1;

    const plan = collectStrApply('A', esc_start | esc_str, &buf, near_limit, &chunk, chunk.len, near_limit);

    try std.testing.expectEqual(@as(c_int, str_collect_abort), plan.first.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.retry);
}

test "strreset plan matches C string buffer size" {
    const plan = st_strresetplan();

    try std.testing.expectEqual(@as(usize, str_buf_size), plan.size);
}

test "tcollectstr aborts when growth would overflow" {
    var buf = [_]u8{0};
    const chunk = [_]u8{'A'};
    const near_limit = (std.math.maxInt(usize) - 4) / 2 + 1;

    const exec = st_tcollectstr('A', esc_start | esc_str, &buf, near_limit, &chunk, chunk.len, near_limit);

    try std.testing.expectEqual(@as(c_int, str_collect_abort), exec.kind);
    try std.testing.expectEqual(@as(usize, near_limit), exec.new_size);
    try std.testing.expectEqual(@as(usize, near_limit), exec.new_len);
}

test "tcollectstr appends chunk after planning" {
    var buf = [_]u8{ 0, 0, 0, 0 };
    const chunk = [_]u8{'X'};

    const exec = st_tcollectstr('A', esc_start | esc_str, &buf, 1, &chunk, chunk.len, buf.len);

    try std.testing.expectEqual(@as(c_int, str_collect_append), exec.kind);
    try std.testing.expectEqual(@as(u8, 'X'), buf[1]);
    try std.testing.expectEqual(@as(usize, 2), exec.new_len);
}

test "str collect transaction describes retry after grow" {
    var buf = [_]u8{0};
    const chunk = [_]u8{ 'A', 'B' };
    const tx = st_strcollecttransaction('A', esc_start | esc_str, &buf, 0, &chunk, chunk.len, buf.len);

    try std.testing.expectEqual(@as(c_int, 2), tx.step_count);
    try std.testing.expectEqual(@as(c_int, str_collect_step_grow_buffer), tx.steps[0].kind);
    try std.testing.expectEqual(@as(c_int, str_collect_grow), tx.steps[0].exec.kind);
    try std.testing.expectEqual(@as(c_int, str_collect_step_retry_collect), tx.steps[1].kind);
}

test "tescflow appends csi byte and finishes on final byte" {
    const exec = st_inputescflowplan(esc_start | esc_csi, 'm', 0, 4);

    try std.testing.expectEqual(@as(c_int, esc_flow_csi), exec.kind);
    try std.testing.expectEqual(@as(c_int, 1), exec.handle_csi);
    try std.testing.expectEqual(@as(c_int, 1), exec.csi_write);
    try std.testing.expectEqual(@as(c_int, 3), exec.action_count);
    try std.testing.expectEqual(@as(c_int, esc_flow_action_write_csi_byte), exec.actions[0]);
    try std.testing.expectEqual(@as(c_int, esc_flow_action_parse_csi), exec.actions[1]);
    try std.testing.expectEqual(@as(c_int, esc_flow_action_handle_csi), exec.actions[2]);
    try std.testing.expectEqual(@as(usize, 1), exec.new_csi_len);
    try std.testing.expectEqual(@as(u8, 'm'), exec.csi_byte);
    try std.testing.expectEqual(@as(c_int, 0), exec.finish_esc);
}

test "tescflow keeps collecting non final csi byte" {
    const exec = st_inputescflowplan(esc_start | esc_csi, '3', 0, 4);

    try std.testing.expectEqual(@as(c_int, esc_flow_csi), exec.kind);
    try std.testing.expectEqual(@as(c_int, 0), exec.handle_csi);
    try std.testing.expectEqual(@as(c_int, 1), exec.csi_write);
    try std.testing.expectEqual(@as(c_int, 1), exec.action_count);
    try std.testing.expectEqual(@as(c_int, esc_flow_action_write_csi_byte), exec.actions[0]);
    try std.testing.expectEqual(@as(usize, 1), exec.new_csi_len);
    try std.testing.expectEqual(@as(u8, '3'), exec.csi_byte);
    try std.testing.expectEqual(@as(c_int, 0), exec.finish_esc);
}

test "tescflow routes utf8 state" {
    const exec = st_inputescflowplan(esc_start | esc_utf8, 'G', 0, 2);

    try std.testing.expectEqual(@as(c_int, esc_flow_utf8), exec.kind);
    try std.testing.expectEqual(@as(c_int, 1), exec.action_count);
    try std.testing.expectEqual(@as(c_int, esc_flow_action_define_utf8), exec.actions[0]);
    try std.testing.expectEqual(@as(usize, 0), exec.new_csi_len);
    try std.testing.expectEqual(@as(c_int, 0), exec.finish_esc);
}

test "clear glyph resets cell using current colors" {
    var line = [_]ZigGlyph{.{ .u = '中', .mode = attr_wide, .fg = 1, .bg = 2 }};
    const attr = ZigGlyph{ .u = 'x', .mode = 9, .fg = 7, .bg = 8 };

    st_tclearglyph(&line, 0, &attr);

    try std.testing.expectEqual(@as(u32, ' '), line[0].u);
    try std.testing.expectEqual(@as(c_ushort, 0), line[0].mode);
    try std.testing.expectEqual(@as(u32, 7), line[0].fg);
    try std.testing.expectEqual(@as(u32, 8), line[0].bg);
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
    const exec = st_inputescplan('[', esc_start, 0, 0, 0);

    try std.testing.expectEqual(@as(c_int, esc_start | esc_csi), exec.state.esc);
    try std.testing.expectEqual(@as(c_int, esc_action_none), exec.action);
    try std.testing.expectEqual(@as(c_int, 0), exec.ret);
}

test "tescexec selects alt charset and returns no action" {
    const exec = st_inputescplan('+', esc_start, 0, 0, 0);

    try std.testing.expectEqual(@as(c_int, esc_start | esc_altcharset), exec.state.esc);
    try std.testing.expectEqual(@as(c_int, 1), exec.state.icharset_set);
    try std.testing.expectEqual(@as(c_int, 3), exec.state.icharset);
    try std.testing.expectEqual(@as(c_int, esc_action_none), exec.action);
}

test "tescexec maps index to action" {
    const exec = st_inputescplan('D', esc_start, 0, 0, 0);

    try std.testing.expectEqual(@as(c_int, esc_action_ind), exec.action);
    try std.testing.expectEqual(@as(c_int, 1), exec.ret);
}

test "controlexec escape updates esc bits" {
    const exec = st_inputcontrolplan('\x1b', esc_csi | esc_altcharset | esc_test, 0, 0);

    try std.testing.expectEqual(@as(c_int, esc_start), exec.state.esc);
    try std.testing.expectEqual(@as(c_int, ctl_action_escape), exec.action);
    try std.testing.expectEqual(@as(c_int, esc_start), exec.finish_esc);
}

test "controlexec lock shift updates charset" {
    const exec = st_inputcontrolplan('\x0e', 0, 0, 0);

    try std.testing.expectEqual(@as(c_int, 1), exec.state.charset_set);
    try std.testing.expectEqual(@as(c_int, 1), exec.state.charset);
    try std.testing.expectEqual(@as(c_int, 1), exec.state.term_update.set_charset);
    try std.testing.expectEqual(@as(c_int, 1), exec.state.term_update.charset);
    try std.testing.expectEqual(@as(c_int, ctl_action_none), exec.action);
}

test "controlexec sets tab stop and clears string" {
    const exec = st_inputcontrolplan(0x88, esc_start | esc_str | esc_str_end, 0, 1);

    try std.testing.expectEqual(@as(c_int, 1), exec.state.tab_set);
    try std.testing.expectEqual(@as(c_int, 1), exec.state.tab_x);
    try std.testing.expectEqual(@as(c_int, esc_start), exec.finish_esc);
}
