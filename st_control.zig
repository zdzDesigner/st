const std = @import("std");

pub const ZigControlPlan = extern struct {
    kind: c_int,
    value: c_int,
};

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

export fn st_plancontrol(ascii: u8) ZigControlPlan {
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

test "tab maps to tab action" {
    const plan = st_plancontrol('\t');
    try std.testing.expectEqual(@as(c_int, ctl_tab), plan.kind);
}

test "escape maps to escape action" {
    const plan = st_plancontrol('\x1b');
    try std.testing.expectEqual(@as(c_int, ctl_escape), plan.kind);
}

test "so selects charset one" {
    const plan = st_plancontrol('\x0e');
    try std.testing.expectEqual(@as(c_int, ctl_lock_shift), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.value);
}

test "si selects charset zero" {
    const plan = st_plancontrol('\x0f');
    try std.testing.expectEqual(@as(c_int, ctl_lock_shift), plan.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.value);
}

test "c1 dcs starts string sequence" {
    const plan = st_plancontrol(0x90);
    try std.testing.expectEqual(@as(c_int, ctl_start_str), plan.kind);
    try std.testing.expectEqual(@as(c_int, 0x90), plan.value);
}

test "ignored nul stays none" {
    const plan = st_plancontrol('\x00');
    try std.testing.expectEqual(@as(c_int, ctl_none), plan.kind);
}
