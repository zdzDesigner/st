/* st_c_harness.h — Zig 端访问 C harness 的最小声明头。
 * [输入]: 无
 * [输出]: extern 函数声明
 * [定位]: 仅用于测试，不进入正式构建路径的导出面。
 */

#ifndef ST_C_HARNESS_H
#define ST_C_HARNESS_H

#include <stdint.h>

void harness_term_init(int cols, int rows);
void harness_term_reset(void);
void harness_commit_putc_write(int advance, int next_x, int y, uint32_t rune);

int  harness_get_dirty(int row);
int  harness_get_cursor_x(void);
int  harness_get_cursor_y(void);
char harness_get_cursor_state(void);
uint32_t harness_get_lastc(void);
int  harness_get_tsetdirt_calls(void);
int  harness_get_tmoveto_calls(void);
int  harness_get_tmoveto_x_last(void);
int  harness_get_tmoveto_y_last(void);

#endif /* ST_C_HARNESS_H */
