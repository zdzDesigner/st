/* Zig/C bridge for gradually migrated helpers. */

#ifndef ST_ZIG_H
#define ST_ZIG_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
	uint32_t rune;
	size_t len;
} ZigUtf8Decode;

#define ST_ZIG_CSI_ARG_SIZ 16

typedef struct {
	char priv;
	int arg[ST_ZIG_CSI_ARG_SIZ];
	int narg;
	char mode[2];
} ZigCsiParse;

typedef struct {
	int32_t idx;
	int input_npar;
	int next_npar;
	int kind;
	unsigned int r;
	unsigned int g;
	unsigned int b;
	int value;
} ZigColorParse;

enum {
	ST_ZIG_COLOR_OK = 0,
	ST_ZIG_COLOR_BAD_COUNT = 1,
	ST_ZIG_COLOR_BAD_RGB = 2,
	ST_ZIG_COLOR_BAD_INDEX = 3,
	ST_ZIG_COLOR_UNKNOWN = 4,
};

typedef struct {
	unsigned short mode;
	uint32_t fg;
	uint32_t bg;
} ZigAttrState;

typedef struct {
	ZigAttrState state;
	int error_kind;
	int error_value;
	int error_index;
	ZigColorParse color_error;
} ZigAttrUpdate;

typedef struct {
	int x1;
	int y1;
	int x2;
	int y2;
} ZigClearRect;

typedef struct {
	int kind;
	int count;
	ZigClearRect rects[2];
} ZigErasePlan;

typedef struct {
	int kind;
	int x;
	int y;
} ZigCursorPlan;

typedef struct {
	int kind;
	int count;
	ZigClearRect rect;
} ZigEditPlan;

typedef struct {
	int kind;
	int value;
	int x;
	int y;
} ZigLightPlan;

typedef struct {
	int kind;
	int top;
	int bottom;
} ZigStatePlan;

typedef struct {
	int kind;
	int value;
	int extra;
} ZigMiscPlan;

typedef struct {
	int kind;
} ZigModePlan;

typedef struct {
	int narg;
	size_t ends[ST_ZIG_CSI_ARG_SIZ];
} ZigStrParse;

typedef struct {
	int kind;
} ZigStrHandlePlan;

typedef struct {
	int kind;
	int value;
	int ret;
} ZigEscPlan;

typedef struct {
	int kind;
	int value;
} ZigControlPlan;

typedef struct {
	int control;
	int width;
	int len;
	unsigned char bytes[4];
} ZigPutcDecode;

typedef struct {
	int kind;
	size_t new_size;
} ZigStrCollectPlan;

typedef struct {
	int kind;
	int finish;
} ZigEscFlowPlan;

typedef struct {
	int kind;
	int finish;
	size_t new_csi_len;
} ZigEscFlowExec;

typedef struct {
	int clear_esc;
	int stop;
} ZigEscFlowAfter;

typedef struct {
	uint32_t u;
	unsigned short mode;
	uint32_t fg;
	uint32_t bg;
} ZigGlyph;

typedef struct {
	int advance;
	int next_x;
} ZigPutcWriteResult;

typedef struct {
	int clear_selection;
	int wrapnext;
	int overflow;
} ZigPutcPreparePlan;

typedef struct {
	int kind;
	int new_esc;
	size_t new_len;
	size_t new_size;
} ZigStrCollectExec;

enum {
	ST_ZIG_ATTR_ERROR_NONE = 0,
	ST_ZIG_ATTR_ERROR_UNKNOWN = 1,
};

enum {
	ST_ZIG_ERASE_OK = 0,
	ST_ZIG_ERASE_UNKNOWN = 1,
};

enum {
	ST_ZIG_CURSOR_MOVE_TO = 0,
	ST_ZIG_CURSOR_MOVE_TO_ABS = 1,
	ST_ZIG_CURSOR_UNKNOWN = 2,
};

enum {
	ST_ZIG_EDIT_INSERT_BLANK = 0,
	ST_ZIG_EDIT_SCROLL_UP = 1,
	ST_ZIG_EDIT_SCROLL_DOWN = 2,
	ST_ZIG_EDIT_INSERT_BLANK_LINE = 3,
	ST_ZIG_EDIT_DELETE_LINE = 4,
	ST_ZIG_EDIT_CLEAR_REGION = 5,
	ST_ZIG_EDIT_DELETE_CHAR = 6,
	ST_ZIG_EDIT_UNKNOWN = 7,
};

enum {
	ST_ZIG_LIGHT_NONE = 0,
	ST_ZIG_LIGHT_CLEAR_TAB_CURRENT = 1,
	ST_ZIG_LIGHT_CLEAR_TAB_ALL = 2,
	ST_ZIG_LIGHT_PUT_TAB = 3,
	ST_ZIG_LIGHT_WRITE_VTIDENT = 4,
	ST_ZIG_LIGHT_WRITE_CURSOR_POSITION = 5,
	ST_ZIG_LIGHT_UNKNOWN = 6,
};

enum {
	ST_ZIG_STATE_UNKNOWN = 0,
	ST_ZIG_STATE_SET_SCROLL = 1,
	ST_ZIG_STATE_SAVE_CURSOR = 2,
	ST_ZIG_STATE_LOAD_CURSOR = 3,
};

enum {
	ST_ZIG_MISC_NONE = 0,
	ST_ZIG_MISC_MEDIA_DUMP = 1,
	ST_ZIG_MISC_MEDIA_DUMP_LINE = 2,
	ST_ZIG_MISC_MEDIA_DUMP_SEL = 3,
	ST_ZIG_MISC_MEDIA_PRINT_OFF = 4,
	ST_ZIG_MISC_MEDIA_PRINT_ON = 5,
	ST_ZIG_MISC_REPEAT_LAST = 6,
	ST_ZIG_MISC_SET_CURSOR_STYLE = 7,
	ST_ZIG_MISC_UNKNOWN = 8,
};

enum {
	ST_ZIG_MODE_IGNORE = 0,
	ST_ZIG_MODE_PRIVATE_UNKNOWN = 1,
	ST_ZIG_MODE_REGULAR_UNKNOWN = 2,
	ST_ZIG_MODE_APPCURSOR = 3,
	ST_ZIG_MODE_REVERSE = 4,
	ST_ZIG_MODE_ORIGIN = 5,
	ST_ZIG_MODE_WRAP = 6,
	ST_ZIG_MODE_CURSOR_VISIBILITY = 7,
	ST_ZIG_MODE_MOUSE_X10 = 8,
	ST_ZIG_MODE_MOUSE_BTN = 9,
	ST_ZIG_MODE_MOUSE_MOTION = 10,
	ST_ZIG_MODE_MOUSE_MANY = 11,
	ST_ZIG_MODE_FOCUS = 12,
	ST_ZIG_MODE_MOUSE_SGR = 13,
	ST_ZIG_MODE_8BIT = 14,
	ST_ZIG_MODE_ALT1049 = 15,
	ST_ZIG_MODE_ALT47 = 16,
	ST_ZIG_MODE_CURSOR1048 = 17,
	ST_ZIG_MODE_BRACKETED_PASTE = 18,
	ST_ZIG_MODE_KBDLOCK = 19,
	ST_ZIG_MODE_INSERT = 20,
	ST_ZIG_MODE_ECHO = 21,
	ST_ZIG_MODE_CRLF = 22,
};

enum {
	ST_ZIG_PUTC_ADVANCE_MOVE = 0,
	ST_ZIG_PUTC_ADVANCE_WRAPNEXT = 1,
};

enum {
	ST_ZIG_SETCHAR_FIX_NONE = 0,
	ST_ZIG_SETCHAR_FIX_CLEAR_RIGHT_DUMMY = 1,
	ST_ZIG_SETCHAR_FIX_CLEAR_LEFT_WIDE = 2,
};

char *st_base64dec(const char *);
ZigUtf8Decode st_utf8decode(const unsigned char *, size_t);
size_t st_utf8encode(uint32_t, unsigned char *);
ZigCsiParse st_csiparse(const unsigned char *, size_t);
ZigColorParse st_tdefcolor(const int *, int, int);
ZigAttrUpdate st_tsetattr(ZigAttrState, uint32_t, uint32_t, const int *, int);
ZigErasePlan st_planerase(char, int, int, int, int, int);
ZigCursorPlan st_plancursor(char, int, int, const int *, int);
ZigEditPlan st_planedit(char, const int *, int, int, int);
ZigLightPlan st_planlight(char, const int *, int, int, int);
ZigStatePlan st_planstate(char, int, const int *, int, int);
ZigMiscPlan st_planmisc(char, char, const int *, int);
ZigModePlan st_planmode(int, int);
ZigStrParse st_strparse(const unsigned char *, size_t);
ZigStrHandlePlan st_planstrhandle(char, int, int);
ZigEscPlan st_planesc(unsigned char);
ZigControlPlan st_plancontrol(unsigned char);
ZigPutcDecode st_putcdecode(uint32_t, int);
void st_tsetchar(uint32_t, const ZigGlyph *, ZigGlyph *, int *, int, int, int);
ZigPutcWriteResult st_tputcwrite(uint32_t, int, const ZigGlyph *, ZigGlyph *, int *, int, int, int, int);
ZigPutcPreparePlan st_tputcprepare(int, int, int, int, int, int);
ZigStrCollectExec st_tcollectstr(uint32_t, int, unsigned char *, size_t, const unsigned char *, size_t, size_t);
ZigEscFlowExec st_tescflow(int, uint32_t, unsigned char *, size_t, size_t);
int st_tcontrolafter(int);
ZigEscFlowAfter st_tescflowafter(int, int);

#endif
