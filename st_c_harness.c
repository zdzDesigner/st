/* st_c_harness.c — 最小 C-side harness，仅验证 tcommitputcwrite 语义。
 *
 * [输入]: st_commit_putc.h 提供的共享协议 + ZigPutcWriteResult
 * [输出]: 可观测的 term 状态变更（dirty / cursor / lastc / WRAPNEXT）
 * [定位]: 独立于正式 build 路径的测试辅助文件，不链接 X11 等重量级依赖。
 * [同步]: docs/issues/03-c-commit-harness.md
 *
 * 关键修复：不再复制 tcommitputcwrite 语义，改为调用 commit_putc()
 * 共享协议，确保 protocol order 唯一来源。
 */

#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "st_zig.h"
#include "st_commit_putc.h"

/* ---------- 最小类型定义（避免拉入 st.h / win.h） ---------- */

typedef uint32_t Rune;

/* TCursor: 与 st.c 第75-80行 一致 */
typedef struct {
    struct { uint32_t u; uint16_t mode; uint32_t fg; uint32_t bg; } attr;
    int x;
    int y;
    char state;
} TestCursor;

/* 单行 buffer，用于最小 term mock */
#define HARNESS_COLS 80
#define HARNESS_ROWS 24

#define LINE_SZ ((size_t)HARNESS_COLS * sizeof(ZigGlyph))

/* ---------- 测试状态（可被 Zig 侧读取 / 写入） ---------- */

typedef struct {
    /* dirtyness per row */
    int dirty[HARNESS_ROWS];
    TestCursor cursor;
    Rune lastc;
    ZigLineRange last_dirt_range;

    /* stub call records */
    int tsetdirt_calls;
    int tsetdirt_top_last;
    int tsetdirt_bot_last;

    int tmoveto_calls;
    int tmoveto_x_last;
    int tmoveto_y_last;
} TermMock;

/* 全局 mock，Zig 测试可在每次 case 前 reset */
TermMock g_mock = {0};

/* ---------- 公开 API（extern → Zig 可直接调用） ---------- */

void harness_term_init(int cols, int rows);
void harness_term_reset(void);
void harness_commit_putc_write(int advance, int next_x, int y, uint32_t rune);

/* 只读观察口 */
int  harness_get_dirty(int row);
int  harness_get_cursor_x(void);
int  harness_get_cursor_y(void);
char harness_get_cursor_state(void);
Rune harness_get_lastc(void);
int  harness_get_tsetdirt_calls(void);
int  harness_get_tmoveto_calls(void);
int  harness_get_tmoveto_x_last(void);
int  harness_get_tmoveto_y_last(void);

/* ---------- 内部 stub（模拟 tsetdirt / tmoveto） ---------- */

static void tsetdirt_stub(int top, int bot, void *ctx) {
    (void)ctx;
    g_mock.tsetdirt_calls++;
    g_mock.tsetdirt_top_last = top;
    g_mock.tsetdirt_bot_last = bot;

    /* 记录 dirty（与 st.c termapplydirtyrange 语义一致） */
    for (int i = top; i <= bot && i < HARNESS_ROWS; i++) {
        if (i >= 0)
            g_mock.dirty[i] = 1;
    }
    g_mock.last_dirt_range.top = top;
    g_mock.last_dirt_range.bot = bot;
}

static void tmoveto_stub(int x, int y, void *ctx) {
    (void)ctx;
    g_mock.tmoveto_calls++;
    g_mock.tmoveto_x_last = x;
    g_mock.tmoveto_y_last = y;
    g_mock.cursor.x = x;
    g_mock.cursor.y = y;
}

/* ---------- 实现：调用共享 commit_putc() 协议 ----------
 *
 * 修复前：直接复制 tcommitputcwrite 语义（st.c#2673 的 clone）
 * 修复后：通过 commit_putc() 调用唯一协议实现，st.c 也调用同一函数。
 *         协议顺序变更时，harness 与生产路径同时失效，防止无声漂变。
 */
void harness_commit_putc_write(int advance, int next_x, int y, uint32_t u) {
    ZigPutcWriteResult write;
    write.advance = advance;
    write.next_x = next_x;

    commit_putc(
        &write,
        y,
        u,
        (int *)&g_mock.lastc,
        &g_mock.cursor.state,
        NULL,
        tsetdirt_stub,
        tmoveto_stub);
}

/* ---------- init / reset ---------- */

void harness_term_init(int cols, int rows) {
    (void)cols;
    (void)rows;
    memset(&g_mock, 0, sizeof(g_mock));
    g_mock.cursor.x = 0;
    g_mock.cursor.y = 0;
    g_mock.cursor.state = 0;
}

void harness_term_reset(void) {
    harness_term_init(HARNESS_COLS, HARNESS_ROWS);
}

/* ---------- 只读观察口 ---------- */

int harness_get_dirty(int row) {
    if (row < 0 || row >= HARNESS_ROWS) return -1;
    return g_mock.dirty[row];
}

int harness_get_cursor_x(void) { return g_mock.cursor.x; }
int harness_get_cursor_y(void) { return g_mock.cursor.y; }
char harness_get_cursor_state(void) { return g_mock.cursor.state; }
Rune harness_get_lastc(void) { return g_mock.lastc; }
int harness_get_tsetdirt_calls(void) { return g_mock.tsetdirt_calls; }
int harness_get_tmoveto_calls(void) { return g_mock.tmoveto_calls; }
int harness_get_tmoveto_x_last(void) { return g_mock.tmoveto_x_last; }
int harness_get_tmoveto_y_last(void) { return g_mock.tmoveto_y_last; }
