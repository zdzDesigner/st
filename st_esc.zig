const std = @import("std");

pub const ZigEscPlan = extern struct {
    kind: c_int,
    value: c_int,
    ret: c_int,
};

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

export fn st_planesc(ascii: u8) ZigEscPlan {
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

test "esc [ enters csi mode" {
    const plan = st_planesc('[');
    try std.testing.expectEqual(@as(c_int, esc_set_csi), plan.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.ret);
}

test "esc ] starts string sequence" {
    const plan = st_planesc(']');
    try std.testing.expectEqual(@as(c_int, esc_start_str), plan.kind);
    try std.testing.expectEqual(@as(c_int, ']'), plan.value);
    try std.testing.expectEqual(@as(c_int, 0), plan.ret);
}

test "esc n sets locking shift 2" {
    const plan = st_planesc('n');
    try std.testing.expectEqual(@as(c_int, esc_lock_shift), plan.kind);
    try std.testing.expectEqual(@as(c_int, 2), plan.value);
}

test "esc plus selects alt charset slot" {
    const plan = st_planesc('+');
    try std.testing.expectEqual(@as(c_int, esc_set_altcharset), plan.kind);
    try std.testing.expectEqual(@as(c_int, 3), plan.value);
    try std.testing.expectEqual(@as(c_int, 0), plan.ret);
}

test "esc backslash maps to string terminator" {
    const plan = st_planesc('\\');
    try std.testing.expectEqual(@as(c_int, esc_st), plan.kind);
}

test "unknown esc stays unknown" {
    const plan = st_planesc('x');
    try std.testing.expectEqual(@as(c_int, esc_unknown), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.ret);
}
