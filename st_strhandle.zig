//! st_strhandle.zig 负责 OSC/DCS 字符串序列的启动规划和动作分类。
//! [输入]: 原始字符串序列控制码、当前 ESC 状态、字符串序列类型、参数数量和第一个参数的整数值。
//! [输出]: `ZigStrSequence` / `ZigStrHandlePlan`，告诉 C 侧应启动哪类 STR，或应设置标题、图标标题、selection、忽略/unknown。
//! [副作用边界]: 不调用 `xsettitle(...)`、`xsetsel(...)`、`xclipcopy(...)`；X11/clipboard 副作用留在 C。
//! [定位]: 收薄 `tstrsequence(...)` / `strhandle(...)` 的分支判断，但保留 C 对外部 UI 状态的控制。

const std = @import("std");
const control_esc = @import("st_control_esc.zig");

pub const ZigStrHandlePlan = extern struct {
    kind: c_int,
    arg1_present: c_int,
    clipboard_run: c_int,
};

pub const ZigStrSequence = extern struct {
    seq_type: u8,
    esc: c_int,
};

pub const str_plan_osc_52 = 0;
pub const str_plan_osc_both_titles = 1;
pub const str_plan_osc_icon_title = 2;
pub const str_plan_osc_window_title = 3;
pub const str_plan_old_title = 4;
pub const str_plan_ignore = 5;
pub const str_plan_unknown = 6;
pub const str_plan_osc_4 = 7;
pub const str_plan_osc_104 = 8;

// STR 启动复用共享 ESC 状态位，避免与 `st_setchar.zig` 的字符串收集状态漂移。
const esc_str = control_esc.esc_str;

const StringSequence = struct {
    control: u8,
    esc: c_int,

    fn start(self: StringSequence) ZigStrSequence {
        return .{
            .seq_type = switch (self.control) {
                0x90 => 'P',
                0x9f => '_',
                0x9e => '^',
                0x9d => ']',
                else => self.control,
            },
            .esc = self.esc | esc_str,
        };
    }
};

const StringAction = struct {
    seq_type: c_char,
    narg: c_int,
    par: c_int,

    fn plan(self: StringAction, allow_window_ops: bool) ZigStrHandlePlan {
        const arg1_present: c_int = if (self.narg > 1) 1 else 0;
        const clipboard_run: c_int = if (self.seq_type == ']' and self.par == 52 and self.narg > 2 and allow_window_ops) 1 else 0;

        return switch (self.seq_type) {
            ']' => switch (self.par) {
                0 => if (self.narg > 1)
                    .{ .kind = str_plan_osc_both_titles, .arg1_present = arg1_present, .clipboard_run = 0 }
                else
                    .{ .kind = str_plan_ignore, .arg1_present = arg1_present, .clipboard_run = 0 },
                1 => if (self.narg > 1)
                    .{ .kind = str_plan_osc_icon_title, .arg1_present = arg1_present, .clipboard_run = 0 }
                else
                    .{ .kind = str_plan_ignore, .arg1_present = arg1_present, .clipboard_run = 0 },
                2 => if (self.narg > 1)
                    .{ .kind = str_plan_osc_window_title, .arg1_present = arg1_present, .clipboard_run = 0 }
                else
                    .{ .kind = str_plan_ignore, .arg1_present = arg1_present, .clipboard_run = 0 },
                52 => .{ .kind = str_plan_osc_52, .arg1_present = arg1_present, .clipboard_run = clipboard_run },
                4 => if (self.narg >= 3)
                    .{ .kind = str_plan_osc_4, .arg1_present = arg1_present, .clipboard_run = 0 }
                else
                    .{ .kind = str_plan_unknown, .arg1_present = arg1_present, .clipboard_run = 0 },
                104 => .{ .kind = str_plan_osc_104, .arg1_present = arg1_present, .clipboard_run = 0 },
                else => .{ .kind = str_plan_unknown, .arg1_present = arg1_present, .clipboard_run = 0 },
            },
            'k' => .{ .kind = str_plan_old_title, .arg1_present = arg1_present, .clipboard_run = 0 },
            'P', '_', '^' => .{ .kind = str_plan_ignore, .arg1_present = arg1_present, .clipboard_run = 0 },
            else => .{ .kind = str_plan_unknown, .arg1_present = arg1_present, .clipboard_run = 0 },
        };
    }
};

export fn st_tstrsequence(c: u8, esc: c_int) ZigStrSequence {
    return (StringSequence{ .control = c, .esc = esc }).start();
}

export fn st_strhandleplan(seq_type: c_char, narg: c_int, par: c_int, allow_window_ops: c_int) ZigStrHandlePlan {
    return (StringAction{ .seq_type = seq_type, .narg = narg, .par = par }).plan(allow_window_ops != 0);
}

test "tstrsequence maps C1 controls to string types" {
    try std.testing.expectEqual(@as(u8, 'P'), st_tstrsequence(0x90, 0).seq_type);
    try std.testing.expectEqual(@as(u8, '_'), st_tstrsequence(0x9f, 0).seq_type);
    try std.testing.expectEqual(@as(u8, '^'), st_tstrsequence(0x9e, 0).seq_type);
    try std.testing.expectEqual(@as(u8, ']'), st_tstrsequence(0x9d, 0).seq_type);
}

test "tstrsequence keeps regular type and sets esc str" {
    const seq = st_tstrsequence(']', 1);

    try std.testing.expectEqual(@as(u8, ']'), seq.seq_type);
    try std.testing.expectEqual(@as(c_int, 5), seq.esc);
}

test "osc 0 with second arg sets both titles" {
    const plan = st_strhandleplan(']', 2, 0, 0);
    try std.testing.expectEqual(@as(c_int, str_plan_osc_both_titles), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.arg1_present);
    try std.testing.expectEqual(@as(c_int, 0), plan.clipboard_run);
}

test "osc 1 without payload is ignored" {
    const plan = st_strhandleplan(']', 1, 1, 0);
    try std.testing.expectEqual(@as(c_int, str_plan_ignore), plan.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.arg1_present);
}

test "osc 52 maps to clipboard action" {
    const plan = st_strhandleplan(']', 3, 52, 1);
    try std.testing.expectEqual(@as(c_int, str_plan_osc_52), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.arg1_present);
    try std.testing.expectEqual(@as(c_int, 1), plan.clipboard_run);
}

test "osc 4 with enough args maps to color set" {
    const plan = st_strhandleplan(']', 3, 4, 0);
    try std.testing.expectEqual(@as(c_int, str_plan_osc_4), plan.kind);
}

test "osc 104 maps to color reset" {
    const plan = st_strhandleplan(']', 1, 104, 0);
    try std.testing.expectEqual(@as(c_int, str_plan_osc_104), plan.kind);
}

test "old title sequence maps to old title action" {
    const plan = st_strhandleplan('k', 1, 0, 0);
    try std.testing.expectEqual(@as(c_int, str_plan_old_title), plan.kind);
}

test "dcs style strings are ignored" {
    const plan = st_strhandleplan('P', 0, 0, 0);
    try std.testing.expectEqual(@as(c_int, str_plan_ignore), plan.kind);
}

test "unknown osc code stays unknown" {
    const plan = st_strhandleplan(']', 1, 99, 0);
    try std.testing.expectEqual(@as(c_int, str_plan_unknown), plan.kind);
}
