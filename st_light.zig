//! st_light.zig 负责轻量 CSI 动作的规划。
//! [输入]: CSI mode、参数数组、当前光标坐标。
//! [输出]: `ZigLightPlan`，描述清 tab、移动 tab、写设备标识或报告光标位置。
//! [副作用边界]: 不写 tty、不修改 tab 数组、不移动 tab；C 侧 `tapplylight(...)` 执行这些动作。
//! [定位]: 收敛 `csihandle(...)` 中 `c/g/I/Z/n` 等轻量分支。

const std = @import("std");

pub const ZigLightPlan = extern struct {
    kind: c_int,
    value: c_int,
    x: c_int,
    y: c_int,
};

pub const light_none = 0;
pub const light_clear_tab_current = 1;
pub const light_clear_tab_all = 2;
pub const light_put_tab = 3;
pub const light_write_vtident = 4;
pub const light_write_cursor_position = 5;
pub const light_unknown = 6;

const LightCommand = struct {
    mode: c_char,
    args: []const c_int,
    x: c_int,
    y: c_int,

    fn plan(self: LightCommand) ZigLightPlan {
        const arg0 = defaultArg(self.args, 0, 0);

        return switch (self.mode) {
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
};

export fn st_planlight(mode: c_char, arg: [*]const c_int, len: c_int, x: c_int, y: c_int) ZigLightPlan {
    const args = arg[0..@intCast(len)];
    return (LightCommand{ .mode = mode, .args = args, .x = x, .y = y }).plan();
}

fn defaultArg(args: []const c_int, index: usize, fallback: c_int) c_int {
    if (index >= args.len) return fallback;
    return args[index];
}

fn countArg(args: []const c_int) c_int {
    const value = defaultArg(args, 0, 0);
    return if (value == 0) 1 else value;
}

test "plan g defaults to clear current tab" {
    const plan = st_planlight('g', &[_]c_int{}, 0, 7, 9);
    try std.testing.expectEqual(@as(c_int, light_clear_tab_current), plan.kind);
}

test "plan g with 3 clears all tabs" {
    const plan = st_planlight('g', &[_]c_int{3}, 1, 7, 9);
    try std.testing.expectEqual(@as(c_int, light_clear_tab_all), plan.kind);
}

test "plan I defaults to one tab forward" {
    const plan = st_planlight('I', &[_]c_int{0}, 1, 7, 9);
    try std.testing.expectEqual(@as(c_int, light_put_tab), plan.kind);
    try std.testing.expectEqual(@as(c_int, 1), plan.value);
}

test "plan Z moves tabs backward" {
    const plan = st_planlight('Z', &[_]c_int{2}, 1, 7, 9);
    try std.testing.expectEqual(@as(c_int, light_put_tab), plan.kind);
    try std.testing.expectEqual(@as(c_int, -2), plan.value);
}

test "plan c writes vt identifier for zero arg" {
    const plan = st_planlight('c', &[_]c_int{0}, 1, 7, 9);
    try std.testing.expectEqual(@as(c_int, light_write_vtident), plan.kind);
}

test "plan n writes cursor position for arg six" {
    const plan = st_planlight('n', &[_]c_int{6}, 1, 7, 9);
    try std.testing.expectEqual(@as(c_int, light_write_cursor_position), plan.kind);
    try std.testing.expectEqual(@as(c_int, 8), plan.x);
    try std.testing.expectEqual(@as(c_int, 10), plan.y);
}

test "plan g invalid arg reports unknown" {
    const plan = st_planlight('g', &[_]c_int{9}, 1, 7, 9);
    try std.testing.expectEqual(@as(c_int, light_unknown), plan.kind);
}
