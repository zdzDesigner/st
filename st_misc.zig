//! st_misc.zig 负责 tty/printer 辅助规划和 DEC 测试 selector。
//! [输入]: tty 写入缓冲、长度限制、printer fd 和 DEC 测试字符。
//! [输出]: 写入 chunk/count、printer 是否可写、stty 长度判断或 DEC 测试判断。
//! [副作用边界]: 不调用 `tdump(...)`、`tputc(...)`、`xsetcursor(...)`、`write(...)`；C 侧执行真实动作。
//! [定位]: 支撑 C executor 的杂项 IO 边界；CSI misc 顶层分类已收敛到 `st_csi.zig`。

const std = @import("std");

pub const ZigMiscPlan = extern struct {
    kind: c_int,
    value: c_int,
    extra: c_int,
};

pub const misc_none = 0;
pub const misc_media_dump = 1;
pub const misc_media_dump_line = 2;
pub const misc_media_dump_sel = 3;
pub const misc_media_print_off = 4;
pub const misc_media_print_on = 5;
pub const misc_repeat_last = 6;
pub const misc_set_cursor_style = 7;
pub const misc_unknown = 8;

const TtyWrite = struct {
    input: []const u8,

    fn chunk(self: TtyWrite) usize {
        var index: usize = 0;
        while (index < self.input.len and self.input[index] != '\r') {
            index += 1;
        }
        return index;
    }
};

test "tty write helper stops at carriage return" {
    try std.testing.expectEqual(@as(usize, 3), (TtyWrite{ .input = "abc\rdef" }).chunk());
    try std.testing.expectEqual(@as(usize, 3), (TtyWrite{ .input = "abc" }).chunk());
}
