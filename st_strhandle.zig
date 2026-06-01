const std = @import("std");

pub const ZigStrHandlePlan = extern struct {
    kind: c_int,
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
