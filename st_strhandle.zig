//! st_strhandle.zig 负责 OSC/DCS 字符串序列的启动规划和动作分类。
//! [输入]: 原始字符串序列控制码、当前 ESC 状态、字符串序列类型、参数数量和第一个参数的整数值。
//! [输出]: `ZigStrSequence` / `ZigStrHandlePlan`，告诉 C 侧应启动哪类 STR，或应设置标题、图标标题、selection、忽略/unknown。
//! [副作用边界]: 不调用 `xsettitle(...)`、`xsetsel(...)`、`xclipcopy(...)`；X11/clipboard 副作用留在 C。
//! [定位]: 收薄 `tstrsequence(...)` / `strhandle(...)` 的分支判断，但保留 C 对外部 UI 状态的控制。

const std = @import("std");

pub const ZigStrHandlePlan = extern struct {
    kind: c_int,
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

const esc_str = 4;

export fn st_tstrsequence(c: u8, esc: c_int) ZigStrSequence {
    return .{
        .seq_type = switch (c) {
            0x90 => 'P',
            0x9f => '_',
            0x9e => '^',
            0x9d => ']',
            else => c,
        },
        .esc = esc | esc_str,
    };
}

export fn st_planstrhandle(seq_type: c_char, narg: c_int, par: c_int) ZigStrHandlePlan {
    return switch (seq_type) {
        ']' => switch (par) {
            0 => if (narg > 1)
                .{ .kind = str_plan_osc_both_titles }
            else
                .{ .kind = str_plan_ignore },
            1 => if (narg > 1)
                .{ .kind = str_plan_osc_icon_title }
            else
                .{ .kind = str_plan_ignore },
            2 => if (narg > 1)
                .{ .kind = str_plan_osc_window_title }
            else
                .{ .kind = str_plan_ignore },
            52 => .{ .kind = str_plan_osc_52 },
            4 => if (narg >= 3)
                .{ .kind = str_plan_osc_4 }
            else
                .{ .kind = str_plan_unknown },
            104 => .{ .kind = str_plan_osc_104 },
            else => .{ .kind = str_plan_unknown },
        },
        'k' => .{ .kind = str_plan_old_title },
        'P', '_', '^' => .{ .kind = str_plan_ignore },
        else => .{ .kind = str_plan_unknown },
    };
}

export fn st_strclipboardrun(narg: c_int, allow_window_ops: c_int) c_int {
    return if (narg > 2 and allow_window_ops != 0) 1 else 0;
}

export fn st_strhasarg(narg: c_int, index: c_int) c_int {
    return if (narg > index) 1 else 0;
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
    const plan = st_planstrhandle(']', 2, 0);
    try std.testing.expectEqual(@as(c_int, str_plan_osc_both_titles), plan.kind);
}

test "osc 1 without payload is ignored" {
    const plan = st_planstrhandle(']', 1, 1);
    try std.testing.expectEqual(@as(c_int, str_plan_ignore), plan.kind);
}

test "osc 52 maps to clipboard action" {
    const plan = st_planstrhandle(']', 3, 52);
    try std.testing.expectEqual(@as(c_int, str_plan_osc_52), plan.kind);
}

test "osc clipboard action requires payload and permission" {
    try std.testing.expectEqual(@as(c_int, 1), st_strclipboardrun(3, 1));
    try std.testing.expectEqual(@as(c_int, 0), st_strclipboardrun(2, 1));
    try std.testing.expectEqual(@as(c_int, 0), st_strclipboardrun(3, 0));
}

test "string argument presence checks index" {
    try std.testing.expectEqual(@as(c_int, 1), st_strhasarg(2, 1));
    try std.testing.expectEqual(@as(c_int, 0), st_strhasarg(1, 1));
}

test "osc 4 with enough args maps to color set" {
    const plan = st_planstrhandle(']', 3, 4);
    try std.testing.expectEqual(@as(c_int, str_plan_osc_4), plan.kind);
}

test "osc 104 maps to color reset" {
    const plan = st_planstrhandle(']', 1, 104);
    try std.testing.expectEqual(@as(c_int, str_plan_osc_104), plan.kind);
}

test "old title sequence maps to old title action" {
    const plan = st_planstrhandle('k', 1, 0);
    try std.testing.expectEqual(@as(c_int, str_plan_old_title), plan.kind);
}

test "dcs style strings are ignored" {
    const plan = st_planstrhandle('P', 0, 0);
    try std.testing.expectEqual(@as(c_int, str_plan_ignore), plan.kind);
}

test "unknown osc code stays unknown" {
    const plan = st_planstrhandle(']', 1, 99);
    try std.testing.expectEqual(@as(c_int, str_plan_unknown), plan.kind);
}
