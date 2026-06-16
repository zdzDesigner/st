//! 终端领域基础类型，不暴露 C ABI。
//! [输入]: Zig 内部领域值。
//! [输出]: 可复用的坐标、尺寸和 glyph mode 判断。
//! [定位]: 作为迁移后 Zig 内部模块的共同模型层，避免每个 C adapter 重复定义基础概念。

pub const Rune = u32;

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Size = struct {
    cols: i32,
    rows: i32,
};

pub const attr_wrap: u16 = 1 << 8;
pub const attr_wdummy: u16 = 1 << 10;

pub fn hasWideDummy(mode: u16) bool {
    return (mode & attr_wdummy) != 0;
}

test "glyph mode detects wide dummy" {
    try @import("std").testing.expect(hasWideDummy(attr_wdummy));
    try @import("std").testing.expect(!hasWideDummy(0));
}
