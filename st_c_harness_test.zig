//! st_c_harness_test.zig — C-side tcommitputcwrite 最小集成验证。
//! [输入]: st_c_harness.c 提供的 extern 函数。
//! [输出]: 对 dirty / cursor move / lastc / WRAPNEXT 提交结果的断言。
//! [定位]: 独立于正式构建路径，只围绕 tcommitputcwrite 语义做端到端验证。
//! [同步]: docs/issues/03-c-commit-harness.md

const std = @import("std");
const c = @cImport(@cInclude("st_c_harness.h"));

/// advance 常量，与 st_zig.h 的 ST_ZIG_PUTC_ADVANCE_* 一致。
const putc_advance_move = 0;
const putc_advance_wrapnext = 1;

/// cursor state bit，与 st.c 的 CURSOR_WRAPNEXT 一致。
const cursor_wrapnext: c_int = 1;

/// 每次 test 前 reset mock term 状态。
fn reset() void {
    c.harness_term_reset();
}

/// 用 u32 比较 lastc（C 侧 Rune = uint32_t）。
fn expectLastc(comptime rune: comptime_int) !void {
    try std.testing.expectEqual(@as(c_uint, rune), c.harness_get_lastc());
}

test "commit putc write: advance=MOVE → dirty + cursor_x update + lastc" {
    reset();

    c.harness_commit_putc_write(putc_advance_move, 5, 3, 'A');

    try std.testing.expectEqual(@as(c_int, 1), c.harness_get_dirty(3));
    try std.testing.expectEqual(@as(c_int, 0), c.harness_get_dirty(2));
    try std.testing.expectEqual(@as(c_int, 0), c.harness_get_dirty(4));

    try std.testing.expectEqual(@as(c_int, 5), c.harness_get_cursor_x());
    try std.testing.expectEqual(@as(c_int, 3), c.harness_get_cursor_y());
    try std.testing.expectEqual(@as(c_int, 0), c.harness_get_cursor_state() & cursor_wrapnext);

    try expectLastc('A');

    try std.testing.expectEqual(@as(c_int, 1), c.harness_get_tsetdirt_calls());
    try std.testing.expectEqual(@as(c_int, 1), c.harness_get_tmoveto_calls());
}

test "commit putc write: advance=WRAPNEXT → dirty + WRAPNEXT set + no move" {
    reset();

    c.harness_commit_putc_write(putc_advance_wrapnext, 80, 5, '好');

    try std.testing.expectEqual(@as(c_int, 1), c.harness_get_dirty(5));

    // WRAPNEXT 分支不调 tmoveto，cursor 保持在 reset 后的 0,0
    try std.testing.expectEqual(@as(c_int, 0), c.harness_get_cursor_x());
    try std.testing.expectEqual(@as(c_int, 0), c.harness_get_cursor_y());
    try std.testing.expectEqual(@as(c_int, cursor_wrapnext), c.harness_get_cursor_state() & cursor_wrapnext);

    try expectLastc('好');

    try std.testing.expectEqual(@as(c_int, 1), c.harness_get_tsetdirt_calls());
    try std.testing.expectEqual(@as(c_int, 0), c.harness_get_tmoveto_calls());
}

test "commit putc write: y=0 marks row 0 dirty" {
    reset();

    c.harness_commit_putc_write(putc_advance_move, 0, 0, ' ');

    try std.testing.expectEqual(@as(c_int, 1), c.harness_get_dirty(0));
    try std.testing.expectEqual(@as(c_int, 0), c.harness_get_dirty(1));
    try std.testing.expectEqual(@as(c_int, 1), c.harness_get_tmoveto_calls());
    try std.testing.expectEqual(@as(c_int, 0), c.harness_get_tmoveto_x_last());
    try std.testing.expectEqual(@as(c_int, 0), c.harness_get_tmoveto_y_last());
}

test "commit putc write: WRAPNEXT bit is OR'ed not replaced" {
    reset();

    c.harness_commit_putc_write(putc_advance_wrapnext, 0, 0, 'z');

    const state = c.harness_get_cursor_state();
    try std.testing.expect(state & cursor_wrapnext != 0);
    // 不应有其他 bit
    try std.testing.expectEqual(@as(c_int, cursor_wrapnext), @as(c_int, state));
}

test "commit putc write: multiple calls accumulate dirty and move correctly" {
    reset();

    c.harness_commit_putc_write(putc_advance_move, 10, 0, '一');
    try std.testing.expectEqual(@as(c_int, 10), c.harness_get_cursor_x());

    c.harness_commit_putc_write(putc_advance_move, 20, 0, '二');
    try std.testing.expectEqual(@as(c_int, 20), c.harness_get_cursor_x());
    try std.testing.expectEqual(@as(c_int, 2), c.harness_get_tsetdirt_calls());
    try std.testing.expectEqual(@as(c_int, 2), c.harness_get_tmoveto_calls());

    c.harness_commit_putc_write(putc_advance_wrapnext, 0, 0, '三');
    try std.testing.expectEqual(@as(c_int, 3), c.harness_get_tsetdirt_calls());
    try std.testing.expectEqual(@as(c_int, 2), c.harness_get_tmoveto_calls());
    try expectLastc('三');
}

test "commit putc write: dirty only affected row" {
    reset();

    c.harness_commit_putc_write(putc_advance_move, 3, 10, ' ');

    // 只有 row 10 被标记 dirty
    for (0..24) |i| {
        if (i == 10) {
            try std.testing.expectEqual(@as(c_int, 1), c.harness_get_dirty(@intCast(i)));
        } else {
            try std.testing.expectEqual(@as(c_int, 0), c.harness_get_dirty(@intCast(i)));
        }
    }
}
