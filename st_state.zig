//! st_state.zig 负责 CSI 状态类序列的纯规划。
//! [输入]: CSI mode、private marker、参数数组和终端行数。
//! [输出]: `ZigStatePlan`，描述设置滚动区域、保存光标或恢复光标。
//! [副作用边界]: 不调用 `tsetscroll(...)` / `tcursor(...)`，不修改光标或 scroll region；这些保留在 C executor。
//! [定位]: 收敛 `csihandle(...)` 中 `r/s/u` 分支，并保持 unknown 路径由 C 处理。

const std = @import("std");

pub const ZigStatePlan = extern struct {
    kind: c_int,
    top: c_int,
    bottom: c_int,
};

pub const state_unknown = 0;
pub const state_set_scroll = 1;
pub const state_save_cursor = 2;
pub const state_load_cursor = 3;

export fn st_planstate(mode: c_char, priv: c_int, arg: [*]const c_int, len: c_int, row: c_int) ZigStatePlan {
    const args = arg[0..@intCast(len)];

    return switch (mode) {
        'r' => if (priv != 0)
            .{ .kind = state_unknown, .top = 0, .bottom = 0 }
        else
            .{
                .kind = state_set_scroll,
                .top = defaultArg(args, 0, 1) - 1,
                .bottom = defaultArg(args, 1, row) - 1,
            },
        's' => .{ .kind = state_save_cursor, .top = 0, .bottom = 0 },
        'u' => .{ .kind = state_load_cursor, .top = 0, .bottom = 0 },
        else => .{ .kind = state_unknown, .top = 0, .bottom = 0 },
    };
}

fn defaultArg(args: []const c_int, index: usize, fallback: c_int) c_int {
    if (index >= args.len) return fallback;
    return if (args[index] == 0) fallback else args[index];
}

test "plan r defaults to full screen scroll region" {
    const plan = st_planstate('r', 0, &[_]c_int{ 0, 0 }, 2, 24);
    try std.testing.expectEqual(@as(c_int, state_set_scroll), plan.kind);
    try std.testing.expectEqual(@as(c_int, 0), plan.top);
    try std.testing.expectEqual(@as(c_int, 23), plan.bottom);
}

test "plan r uses explicit bounds" {
    const plan = st_planstate('r', 0, &[_]c_int{ 2, 10 }, 2, 24);
    try std.testing.expectEqual(@as(c_int, state_set_scroll), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.top);
    try std.testing.expectEqual(@as(c_int, 9), plan.bottom);
}

test "plan r with private marker is unknown" {
    const plan = st_planstate('r', 1, &[_]c_int{ 2, 10 }, 2, 24);
    try std.testing.expectEqual(@as(c_int, state_unknown), plan.kind);
}

test "plan s saves cursor" {
    const plan = st_planstate('s', 0, &[_]c_int{}, 0, 24);
    try std.testing.expectEqual(@as(c_int, state_save_cursor), plan.kind);
}

test "plan u loads cursor" {
    const plan = st_planstate('u', 0, &[_]c_int{}, 0, 24);
    try std.testing.expectEqual(@as(c_int, state_load_cursor), plan.kind);
}
