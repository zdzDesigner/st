//! st_control_esc.zig 承载 ESC/control 字节到执行计划的纯决策逻辑。
//! [输入]: C 侧传入的 ASCII/control 字节，以及显式传入的 ESC、charset、tab 状态指针。
//! [输出]: ESC/control plan 和 executor 返回值。
//! [定位]: `st_setchar.zig` 的领域子模块，避免把 ESC/control 决策长期放在 C ABI adapter 文件中。
//! [同步]: 修改本文件时需同步 `st_setchar.zig` 和 `docs/zig-architecture.md`。

// ESC 状态位是跨 `st_setchar.zig` 和 `st_strhandle.zig` 共享的权威定义，禁止在调用方重复硬编码。
pub const esc_start: c_int = 1;
pub const esc_csi: c_int = 2;
pub const esc_altcharset: c_int = 8;
pub const esc_test: c_int = 32;
pub const esc_utf8: c_int = 64;
pub const esc_str: c_int = 4;
pub const esc_str_end: c_int = 16;

// ESC plan kind 只表达本模块内部决策结果，C 侧消费的是转换后的 `esc_action_*`。
pub const esc_unknown = 0;
pub const esc_set_csi = 1;
pub const esc_set_test = 2;
pub const esc_set_utf8 = 3;
pub const esc_start_str = 4;
pub const esc_lock_shift = 5;
pub const esc_set_altcharset = 6;
pub const esc_ind = 7;
pub const esc_nel = 8;
pub const esc_hts = 9;
pub const esc_ri = 10;
pub const esc_decid = 11;
pub const esc_ris = 12;
pub const esc_keypad_app = 13;
pub const esc_keypad_normal = 14;
pub const esc_cursor_save = 15;
pub const esc_cursor_load = 16;
pub const esc_st = 17;
pub const esc_action_none = 0;
pub const esc_action_start_str = 1;
pub const esc_action_ind = 2;
pub const esc_action_nel = 3;
pub const esc_action_ri = 4;
pub const esc_action_decid = 5;
pub const esc_action_ris = 6;
pub const esc_action_keypad_app = 7;
pub const esc_action_keypad_normal = 8;
pub const esc_action_cursor_save = 9;
pub const esc_action_cursor_load = 10;
pub const esc_action_st = 11;
pub const esc_action_unknown = 12;

// Control plan kind 只用于把输入控制字节映射到后续 executor action。
pub const ctl_none = 0;
pub const ctl_tab = 1;
pub const ctl_backspace = 2;
pub const ctl_carriage_return = 3;
pub const ctl_linefeed = 4;
pub const ctl_bell = 5;
pub const ctl_escape = 6;
pub const ctl_lock_shift = 7;
pub const ctl_substitute = 8;
pub const ctl_cancel = 9;
pub const ctl_next_line = 10;
pub const ctl_set_tab_stop = 11;
pub const ctl_decid = 12;
pub const ctl_start_str = 13;
pub const ctl_action_none = 0;
pub const ctl_action_tab = 1;
pub const ctl_action_backspace = 2;
pub const ctl_action_carriage_return = 3;
pub const ctl_action_linefeed = 4;
pub const ctl_action_bell = 5;
pub const ctl_action_escape = 6;
pub const ctl_action_substitute = 7;
pub const ctl_action_cancel = 8;
pub const ctl_action_next_line = 9;
pub const ctl_action_decid = 10;
pub const ctl_action_start_str = 11;

pub const ZigEscPlan = extern struct {
    kind: c_int,
    value: c_int,
    ret: c_int,
};

pub const ZigEscExec = extern struct {
    action: c_int,
    ret: c_int,
};

const ZigControlPlan = extern struct {
    kind: c_int,
    value: c_int,
};

pub const ZigControlExec = extern struct {
    action: c_int,
    clear_str: c_int,
};

pub const EscSequence = struct {
    ascii: u8,

    pub fn plan(self: EscSequence) ZigEscPlan {
        return switch (self.ascii) {
            '[' => .{ .kind = esc_set_csi, .value = 0, .ret = 0 },
            '#' => .{ .kind = esc_set_test, .value = 0, .ret = 0 },
            '%' => .{ .kind = esc_set_utf8, .value = 0, .ret = 0 },
            'P', '_', '^', ']', 'k' => .{ .kind = esc_start_str, .value = self.ascii, .ret = 0 },
            'n', 'o' => .{ .kind = esc_lock_shift, .value = 2 + @as(c_int, self.ascii - 'n'), .ret = 1 },
            '(', ')', '*', '+' => .{ .kind = esc_set_altcharset, .value = @as(c_int, self.ascii - '('), .ret = 0 },
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

    pub fn exec(self: EscSequence, esc: *c_int, charset: *c_int, icharset: *c_int, tabs: [*]c_int, x: c_int) ZigEscExec {
        const result = self.plan();

        switch (result.kind) {
            esc_set_csi => esc.* |= esc_csi,
            esc_set_test => esc.* |= esc_test,
            esc_set_utf8 => esc.* |= esc_utf8,
            esc_lock_shift => charset.* = result.value,
            esc_set_altcharset => {
                icharset.* = result.value;
                esc.* |= esc_altcharset;
            },
            esc_hts => tabs[@intCast(x)] = 1,
            else => {},
        }

        return .{
            .action = action(result.kind),
            .ret = result.ret,
        };
    }

    pub fn action(kind: c_int) c_int {
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
};

pub const ControlSequence = struct {
    ascii: u8,

    pub fn plan(self: ControlSequence) ZigControlPlan {
        return switch (self.ascii) {
            '\t' => .{ .kind = ctl_tab, .value = 0 },
            0x08 => .{ .kind = ctl_backspace, .value = 0 },
            '\r' => .{ .kind = ctl_carriage_return, .value = 0 },
            0x0c, 0x0b, '\n' => .{ .kind = ctl_linefeed, .value = 0 },
            0x07 => .{ .kind = ctl_bell, .value = 0 },
            '\x1b' => .{ .kind = ctl_escape, .value = 0 },
            '\x0e', '\x0f' => .{ .kind = ctl_lock_shift, .value = 1 - @as(c_int, self.ascii - '\x0e') },
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
            0x90, 0x9d, 0x9e, 0x9f => .{ .kind = ctl_start_str, .value = self.ascii },
            else => .{ .kind = ctl_none, .value = 0 },
        };
    }

    pub fn exec(self: ControlSequence, esc: *c_int, charset: *c_int, tabs: [*]c_int, x: c_int) ZigControlExec {
        const result = self.plan();

        switch (result.kind) {
            ctl_escape => {
                esc.* &= ~(esc_csi | esc_altcharset | esc_test);
                esc.* |= esc_start;
            },
            ctl_lock_shift => charset.* = result.value,
            ctl_set_tab_stop => tabs[@intCast(x)] = 1,
            else => {},
        }

        return .{
            .action = action(result.kind),
            .clear_str = if (ControlSequence.clearsString(result.kind)) 1 else 0,
        };
    }

    pub fn action(kind: c_int) c_int {
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

    pub fn clearsString(kind: c_int) bool {
        return switch (kind) {
            ctl_bell, ctl_substitute, ctl_cancel, ctl_next_line, ctl_set_tab_stop, ctl_decid => true,
            else => false,
        };
    }
};

test "esc planner enters csi mode" {
    const std = @import("std");
    const plan = (EscSequence{ .ascii = '[' }).plan();
    try std.testing.expectEqual(@as(c_int, esc_set_csi), plan.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.ret);
}

test "control executor sets tab stop and clears string" {
    const std = @import("std");
    var esc: c_int = 0;
    var charset: c_int = 0;
    var tabs = [_]c_int{ 0, 0 };

    const exec = (ControlSequence{ .ascii = 0x88 }).exec(&esc, &charset, &tabs, 1);

    try std.testing.expectEqual(@as(c_int, 1), tabs[1]);
    try std.testing.expectEqual(@as(c_int, 1), exec.clear_str);
}
