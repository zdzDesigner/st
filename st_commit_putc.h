/* st_commit_putc.h — 共享 putc commit 协议，production 与 harness 调用同一实现。
 *
 * [输入]: 回调 + lastc/state 指针 + write 参数
 * [输出]: 通过回调更新 dirty/cursor/lastc
 * [定位]: 协议唯一来源，确保 harness 与 st.c 的 tcommitputcwrite 同序验证。
 * [同步]: .scratch/putc-atomic-commit-owner/issues/03-c-commit-harness.md
 */

#ifndef ST_COMMIT_PUTC_H
#define ST_COMMIT_PUTC_H

#include <stdint.h>
#include "st_zig.h"

/* CURSOR_WRAPNEXT: 与 st.c 第61行 enum cursor_state 一致。
 * 此值自 8ea88fe7 以来稳定为 1，独立定义避免把 enum 暴露给 Zig 构建路径。
 */
enum { ST_COMMIT_PUTC_CURSOR_WRAPNEXT = 1 };

/* 回调签名：各调用方提供自己的实现 */
typedef void (*st_commit_setdirty_fn)(int top, int bot, void *ctx);
typedef void (*st_commit_moveto_fn)(int x, int y, void *ctx);

/** 协议顺序（不可变，与 st.c tcommitputcwrite 原子等价）：
 *  1) setdirty(y, y)          — 标记当前行 dirty
 *  2) *lastc = u              — 记录最后写入的字符
 *  3) advance==MOVE           — moveto(next_x, y)
 *     advance==WRAPNEXT       — *state |= CURSOR_WRAPNEXT
 *
 *  任何顺序变更都会使 harness 断言失败（harness 直接观测此序列效果）。
 *
 *  注意：函数名使用 commit_putc（无 st_ 前缀），因为 st_* 是项目 ABI 符号
 *  命名空间，此 static inline helper 不属于公开 ABI，不应被 ABI 守卫误判。
 */
static inline void commit_putc(
    const ZigPutcWriteResult *write,
    int y,
    uint32_t u,
    int *lastc,
    char *state,
    void *ctx,
    st_commit_setdirty_fn setdirty_cb,
    st_commit_moveto_fn moveto_cb)
{
    /* Step 1: 标记当前行 dirty */
    setdirty_cb(y, y, ctx);

    /* Step 2: 记录最后写入字符 */
    *lastc = (int)u;

    /* Step 3: 根据 advance 决策 cursor 行为 */
    if (write->advance == ST_ZIG_PUTC_ADVANCE_MOVE) {
        moveto_cb(write->next_x, y, ctx);
    } else {
        *state |= (char)ST_COMMIT_PUTC_CURSOR_WRAPNEXT;
    }
}

#endif /* ST_COMMIT_PUTC_H */
