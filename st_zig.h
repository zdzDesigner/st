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

enum {
	ST_ZIG_STR_BUF_SIZ = 512,
};

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
	int state;
	int x;
	int y;
	int col;
	int row;
	int top;
	int bot;
} ZigTermCursorSnapshot;

typedef struct {
	int set_cursor;
	unsigned short cursor_attr_mode;
	uint32_t cursor_fg;
	uint32_t cursor_bg;
	int cursor_x;
	int cursor_y;
	int cursor_state;
	int mode_mask;
	int mode_bits;
	int cursor_state_mask;
	int cursor_state_bits;
	int set_charset;
	int charset;
	int set_trantbl;
	int trantbl_slot;
	int trantbl_charset;
	int set_all_trantbl;
	int all_trantbl_charset;
	int set_scroll_region;
	int top;
	int bot;
	int set_dimensions;
	int col;
	int maxcol;
	int row;
	int clamp_cursor;
} ZigTermStateUpdate;

typedef struct {
	int action;
	int x;
	int y;
	int state;
	int scroll;
	int scroll_down;
	int scroll_top;
	int slot;
} ZigTermCursorPlan;

typedef struct {
	int x;
	int y;
	int state;
	int dirty;
	int dirty_top;
	int dirty_bot;
} ZigBackspacePlan;

typedef struct {
	int search_active;
	int scr;
	int cx;
	int current_y;
	int ocx;
	int ocy;
	int col;
	int row;
} ZigTermFrameSnapshot;

typedef struct {
	int kind;
	int arg;
	int index_arg;
} ZigPlatformEffect;

typedef struct {
	int count;
	ZigPlatformEffect effects[8];
} ZigPlatformEffectList;

typedef struct {
	int cx;
	int cy;
	int ocx;
	int ocy;
	int new_ocx;
	int new_ocy;
	ZigPlatformEffectList platform;
} ZigDrawExecPlan;

typedef struct {
	int draw;
	int y;
	int next_y;
} ZigDrawRegionPlan;

typedef struct {
	int step_count;
	ZigPlatformEffect steps[2048];
} ZigDrawRegionTransaction;

enum {
	ST_ZIG_CURSOR_STORE_NONE = 0,
	ST_ZIG_CURSOR_STORE_SAVE = 1,
	ST_ZIG_CURSOR_STORE_LOAD = 2,
};

typedef struct {
	int kind;
	int count;
	ZigClearRect rect;
} ZigEditPlan;

typedef struct {
	int dst;
	int src;
	int size;
	int clear_x1;
	int clear_x2;
} ZigEditMove;

typedef struct {
	int kind;
	int a;
	int b;
	int c;
	int d;
} ZigScrollStep;

typedef struct {
	int count;
	int new_scr;
	int new_histi;
	int hist_swap;
	int hist_line;
	int line_start;
	int line_end;
	int line_step;
	int line_offset;
	int selscroll_delta;
	int clear_x1;
	int clear_y1;
	int clear_x2;
	int clear_y2;
	int dirty_top;
	int dirty_bot;
	int step_count;
	ZigScrollStep steps[6];
} ZigScrollPlan;

typedef struct {
	int run;
	int new_scr;
	int delta;
	int selscroll_delta;
	int full_dirty;
} ZigKScrollPlan;

enum {
	ST_ZIG_SCROLL_STEP_HIST_SWAP = 1,
	ST_ZIG_SCROLL_STEP_SCR_UPDATE = 2,
	ST_ZIG_SCROLL_STEP_CLEAR_RECT = 3,
	ST_ZIG_SCROLL_STEP_DIRTY_RANGE = 4,
	ST_ZIG_SCROLL_STEP_LINE_SWAP_LOOP = 5,
	ST_ZIG_SCROLL_STEP_SELECTION_SCROLL = 6,
};

typedef struct {
	int kind;
	int value;
	int x;
	int y;
	int tab_clear_current;
	int tab_clear_all;
} ZigLightPlan;

typedef struct {
	int kind;
	int top;
	int bottom;
	int cursor_home;
} ZigStatePlan;

typedef struct {
	int top;
	int bottom;
} ZigScrollRegion;

typedef struct {
	int invalid;
	int requested_col;
	int alloc_col;
	int base_maxcol;
	int minrow;
	int mincol;
	int slide_count;
	int tail_start;
	int resize_rows;
	int new_row_start;
} ZigResizePlan;

typedef struct {
	unsigned short cursor_attr_mode;
	uint32_t cursor_fg;
	uint32_t cursor_bg;
	int cursor_x;
	int cursor_y;
	int cursor_state;
	int top;
	int bot;
	int mode;
	int charset;
	int trantbl;
} ZigResetPlan;

typedef struct {
	int move_home;
	int save_cursor;
	int clear;
	int swap_screen;
} ZigResetScreenStep;

typedef struct {
	ZigResetPlan state;
	int screen_step_count;
	ZigResetScreenStep screen_steps[2];
	ZigTermStateUpdate term_update;
} ZigResetExecPlan;

typedef struct {
	int count;
	ZigClearRect rects[2];
} ZigResizeClearPlan;

typedef struct {
	int grow;
	int clear_start;
	int clear_count;
	int tab_start;
} ZigResizeTabPlan;

typedef struct {
	int run;
	int start;
	int end;
} ZigResizeFillPlan;

typedef struct {
	int resize_start;
	int resize_end;
	int alloc_start;
	int alloc_end;
} ZigResizeRowPlan;

typedef struct {
	ZigResizePlan base;
	ZigResizeFillPlan hist_fill;
	ZigResizeRowPlan rows;
	ZigResizeTabPlan tabs;
	ZigResizeClearPlan clear;
	int step_count;
	int steps[10];
	ZigTermStateUpdate term_update;
} ZigResizeExecPlan;

enum {
	ST_ZIG_RESIZE_STEP_FREE_SLIDE_ROWS = 1,
	ST_ZIG_RESIZE_STEP_MEMMOVE_SLIDE_ROWS = 2,
	ST_ZIG_RESIZE_STEP_FREE_TAIL_ROWS = 3,
	ST_ZIG_RESIZE_STEP_REALLOC_ARRAYS = 4,
	ST_ZIG_RESIZE_STEP_FILL_HISTORY = 5,
	ST_ZIG_RESIZE_STEP_REALLOC_ROWS = 6,
	ST_ZIG_RESIZE_STEP_ALLOC_ROWS = 7,
	ST_ZIG_RESIZE_STEP_TABS = 8,
	ST_ZIG_RESIZE_STEP_UPDATE_DIMENSIONS = 9,
	ST_ZIG_RESIZE_STEP_CLEAR_REGIONS = 10,
};

typedef struct {
	int kind;
	int value;
	int extra;
	int mode_mask;
	int mode_bits;
} ZigMiscPlan;

typedef struct {
	int kind;
	size_t offset;
	size_t len;
} ZigIoEffect;

typedef struct {
	int count;
	size_t consumed;
	ZigIoEffect effects[32];
} ZigIoEffectList;

typedef struct {
	int kind;
	int mode_set;
	ZigEditPlan edit;
	ZigCursorPlan cursor;
	ZigMiscPlan misc;
	ZigLightPlan light;
	ZigErasePlan erase;
	ZigStatePlan state;
} ZigCsiExecPlan;

enum {
	ST_ZIG_PLATFORM_EFFECT_NONE = 0,
	ST_ZIG_PLATFORM_EFFECT_SET_TITLE = 1,
	ST_ZIG_PLATFORM_EFFECT_SET_ICON_TITLE = 2,
	ST_ZIG_PLATFORM_EFFECT_DECODE_CLIPBOARD = 3,
	ST_ZIG_PLATFORM_EFFECT_SET_SELECTION = 4,
	ST_ZIG_PLATFORM_EFFECT_COPY_CLIPBOARD = 5,
	ST_ZIG_PLATFORM_EFFECT_SET_COLOR = 6,
	ST_ZIG_PLATFORM_EFFECT_RESET_COLOR = 7,
	ST_ZIG_PLATFORM_EFFECT_REDRAW = 8,
	ST_ZIG_PLATFORM_EFFECT_UNKNOWN_STR = 9,
	ST_ZIG_PLATFORM_EFFECT_XSETMODE = 10,
	ST_ZIG_PLATFORM_EFFECT_POINTER_MOTION = 11,
	ST_ZIG_PLATFORM_EFFECT_CURSOR = 12,
	ST_ZIG_PLATFORM_EFFECT_CLEAR_SCREEN = 13,
	ST_ZIG_PLATFORM_EFFECT_SWAP_SCREEN = 14,
	ST_ZIG_PLATFORM_EFFECT_MOVE_ORIGIN = 15,
	ST_ZIG_PLATFORM_EFFECT_SEARCH_SCAN = 16,
	ST_ZIG_PLATFORM_EFFECT_DRAW_REGION = 17,
	ST_ZIG_PLATFORM_EFFECT_DRAW_CURSOR = 18,
	ST_ZIG_PLATFORM_EFFECT_FINISH_DRAW = 19,
	ST_ZIG_PLATFORM_EFFECT_IME_SPOT = 20,
	ST_ZIG_PLATFORM_EFFECT_MODE_UNKNOWN_PRIVATE = 21,
	ST_ZIG_PLATFORM_EFFECT_MODE_UNKNOWN_REGULAR = 22,
	ST_ZIG_PLATFORM_EFFECT_REGION_CLEAR_DIRTY = 23,
	ST_ZIG_PLATFORM_EFFECT_REGION_DRAW_LINE = 24,
	ST_ZIG_PLATFORM_EFFECT_REGION_ADVANCE = 25,
};

enum {
	ST_ZIG_PLATFORM_MODE_APPCURSOR = 1,
	ST_ZIG_PLATFORM_MODE_REVERSE = 2,
	ST_ZIG_PLATFORM_MODE_HIDE = 3,
	ST_ZIG_PLATFORM_MODE_MOUSE = 4,
	ST_ZIG_PLATFORM_MODE_MOUSEX10 = 5,
	ST_ZIG_PLATFORM_MODE_MOUSEBTN = 6,
	ST_ZIG_PLATFORM_MODE_MOUSEMOTION = 7,
	ST_ZIG_PLATFORM_MODE_MOUSEMANY = 8,
	ST_ZIG_PLATFORM_MODE_FOCUS = 9,
	ST_ZIG_PLATFORM_MODE_MOUSESGR = 10,
	ST_ZIG_PLATFORM_MODE_8BIT = 11,
	ST_ZIG_PLATFORM_MODE_BRCKTPASTE = 12,
	ST_ZIG_PLATFORM_MODE_KBDLOCK = 13,
};

typedef struct {
	int kind;
	int cursor_state_mask;
	int cursor_state_bits;
	int move_origin_home;
	int mode_mask;
	int mode_bits;
	ZigPlatformEffectList platform;
	ZigTermStateUpdate term_update;
} ZigModePlan;

typedef struct {
	int narg;
	size_t starts[ST_ZIG_CSI_ARG_SIZ];
	size_t ends[ST_ZIG_CSI_ARG_SIZ];
	int nul_terms[ST_ZIG_CSI_ARG_SIZ];
} ZigStrParse;

typedef struct {
	int kind;
	int arg1_present;
	int clipboard_run;
	int payload_arg;
	int color_arg;
} ZigStrHandlePlan;

typedef struct {
	int arg;
	int default_value;
	int use_arg;
} ZigStrHandleParPlan;

typedef struct {
	unsigned char seq_type;
	int esc;
} ZigStrSequence;

typedef struct {
	int esc;
	int charset_set;
	int charset;
	int icharset_set;
	int icharset;
	int tab_set;
	int tab_x;
	ZigTermStateUpdate term_update;
} ZigInputScalarStateUpdate;

typedef struct {
	int action;
	int finish_esc;
	ZigInputScalarStateUpdate state;
} ZigInputControlPlan;

typedef struct {
	int action;
	int ret;
	ZigInputScalarStateUpdate state;
} ZigInputEscPlan;

typedef struct {
	int kind;
	int new_esc;
	size_t new_len;
	size_t new_size;
} ZigStrCollectExec;

typedef struct {
	int kind;
	ZigStrCollectExec exec;
} ZigStrCollectStep;

typedef struct {
	int step_count;
	ZigStrCollectStep steps[4];
} ZigStrCollectTransaction;

typedef struct {
	int kind;
	int action_count;
	int actions[3];
	int handle_csi;
	int csi_write;
	unsigned char csi_byte;
	size_t new_csi_len;
	int finish_esc;
} ZigInputEscFlowPlan;

typedef struct {
	int clear_selection;
	int wrapnext_newline;
	int overflow_newline;
	int write_glyph;
	int mark_dirty;
	int advance;
	int next_x;
	int cursor_state_mask;
	int cursor_state_bits;
} ZigPutcStepPlan;

typedef struct {
	int is_str;
	int is_control;
	int is_esc;
} ZigInputRoutingPlan;

typedef struct {
	int route;
	int print;
	ZigInputRoutingPlan routing;
	ZigStrCollectTransaction collect;
	ZigInputControlPlan control;
	ZigInputEscFlowPlan esc_flow;
	ZigPutcStepPlan putc;
} ZigInputStepPlan;

enum {
	ST_ZIG_INPUT_ROUTE_GRAPHIC = 0,
	ST_ZIG_INPUT_ROUTE_STR = 1,
	ST_ZIG_INPUT_ROUTE_CONTROL = 2,
	ST_ZIG_INPUT_ROUTE_ESC = 3,
};

enum {
	ST_ZIG_CTL_ACTION_NONE = 0,
	ST_ZIG_CTL_ACTION_TAB = 1,
	ST_ZIG_CTL_ACTION_BACKSPACE = 2,
	ST_ZIG_CTL_ACTION_CARRIAGE_RETURN = 3,
	ST_ZIG_CTL_ACTION_LINEFEED = 4,
	ST_ZIG_CTL_ACTION_BELL = 5,
	ST_ZIG_CTL_ACTION_ESCAPE = 6,
	ST_ZIG_CTL_ACTION_SUBSTITUTE = 7,
	ST_ZIG_CTL_ACTION_CANCEL = 8,
	ST_ZIG_CTL_ACTION_NEXT_LINE = 9,
	ST_ZIG_CTL_ACTION_DECID = 10,
	ST_ZIG_CTL_ACTION_START_STR = 11,
};

enum {
	ST_ZIG_ESC_ACTION_START_STR = 1,
	ST_ZIG_ESC_ACTION_IND = 2,
	ST_ZIG_ESC_ACTION_NEL = 3,
	ST_ZIG_ESC_ACTION_RI = 4,
	ST_ZIG_ESC_ACTION_DECID = 5,
	ST_ZIG_ESC_ACTION_RIS = 6,
	ST_ZIG_ESC_ACTION_KEYPAD_APP = 7,
	ST_ZIG_ESC_ACTION_KEYPAD_NORMAL = 8,
	ST_ZIG_ESC_ACTION_CURSOR_SAVE = 9,
	ST_ZIG_ESC_ACTION_CURSOR_LOAD = 10,
	ST_ZIG_ESC_ACTION_ST = 11,
	ST_ZIG_ESC_ACTION_UNKNOWN = 12,
};

typedef struct {
	int control;
	int width;
	int len;
	unsigned char bytes[4];
} ZigPutcDecode;

typedef struct {
	uint32_t rune;
	int caret;
	int bracket;
} ZigWriteControlPlan;

enum {
	ST_ZIG_ESC_FLOW_CSI = 1,
	ST_ZIG_ESC_FLOW_UTF8 = 2,
	ST_ZIG_ESC_FLOW_ALTCHARSET = 3,
	ST_ZIG_ESC_FLOW_TEST = 4,
	ST_ZIG_ESC_FLOW_ESC = 5,
};

enum {
	ST_ZIG_ESC_FLOW_ACTION_WRITE_CSI_BYTE = 1,
	ST_ZIG_ESC_FLOW_ACTION_PARSE_CSI = 2,
	ST_ZIG_ESC_FLOW_ACTION_HANDLE_CSI = 3,
	ST_ZIG_ESC_FLOW_ACTION_DEFINE_UTF8 = 4,
	ST_ZIG_ESC_FLOW_ACTION_DEFINE_CHARSET = 5,
	ST_ZIG_ESC_FLOW_ACTION_DEC_TEST = 6,
	ST_ZIG_ESC_FLOW_ACTION_ESC_HANDLE = 7,
};

typedef struct {
	uint32_t u;
	unsigned short mode;
	uint32_t fg;
	uint32_t bg;
} ZigGlyph;

typedef struct {
	int write;
	int last;
} ZigDumpLinePlan;

typedef struct {
	int top;
	int bot;
} ZigLineRange;

typedef struct {
	int action;
	int ob_y;
	int oe_y;
} ZigSelScrollPlan;

typedef struct {
	int dirty;
	int top;
	int bot;
	int mode;
} ZigSelExtendPlan;

typedef struct {
	int mode;
	int sel_type;
	int alt;
	int snap;
	int x;
	int y;
	int final_mode;
} ZigSelStartPlan;

typedef struct {
	int mode;
	int selection_type;
	int alt;
	int snap;
	int ob_x;
	int ob_y;
	int oe_x;
	int oe_y;
	int nb_x;
	int nb_y;
	int ne_x;
	int ne_y;
} ZigSelectionSnapshot;

typedef struct {
	int mode;
	int selection_type;
	int alt;
	int snap;
	int ob_x;
	int ob_y;
	int oe_x;
	int oe_y;
	int nb_x;
	int nb_y;
	int ne_x;
	int ne_y;
} ZigSelectionStateUpdate;

typedef struct {
	int dirty;
	int top;
	int bot;
	int clear;
} ZigSelectionEffectPlan;

typedef struct {
	ZigSelectionStateUpdate update;
	ZigSelectionEffectPlan effect;
} ZigSelectionStateResult;

typedef struct {
	int x;
	int y;
	int wrap_x;
	int wrap_y;
	int wrapped;
	int in_bounds;
} ZigSelSnapWordPlan;

typedef struct {
	int action;
	int x;
	int y;
	int prevdelim;
	uint32_t prevrune;
} ZigSelSnapWordStep;

typedef struct {
	int action;
	int x;
	int y;
	int wrap_x;
	int wrap_y;
	int wrapped;
} ZigSelSnapWordIterRequest;

typedef struct {
	int wrap_allowed;
	int linelen;
	unsigned short mode;
	int delim;
	uint32_t rune;
} ZigSelSnapWordReaderSnapshot;

typedef struct {
	int x;
	int y;
	int wrap_x;
	int wrap_y;
	int wrapped;
	int in_bounds;
	int wrap_allowed;
	int linelen;
	unsigned short mode;
	int delim;
	int prevdelim;
	uint32_t rune;
	uint32_t prevrune;
} ZigSelSnapWordLoopSnapshot;

typedef struct {
	int action;
	int y;
} ZigSelSnapLineStep;

typedef struct {
	int empty;
	int start_x;
	int last_index;
	int newline;
	int bufsize;
} ZigGetSelExecPlan;

typedef struct {
	int bufsize;
	int start_y;
	int end_y;
	int step_count;
	int steps[3];
} ZigSelectionExtractTransaction;

enum {
	ST_ZIG_SELECTION_EXTRACT_ALLOC_BUFFER = 1,
	ST_ZIG_SELECTION_EXTRACT_COPY_LINES = 2,
	ST_ZIG_SELECTION_EXTRACT_FINISH_NUL = 3,
};

typedef struct {
	int run;
	int current;
} ZigSearchStepPlan;

typedef struct {
	int active;
	size_t len;
	size_t cursor;
	size_t cap;
} ZigSearchInputState;

typedef struct {
	int kind;
	size_t start;
	size_t end;
	size_t cursor;
} ZigSearchCursorEditPlan;

typedef struct {
	int kind;
	size_t inputlen;
	size_t inputcursor;
} ZigSearchStateEditPlan;

typedef struct {
	int run;
	int new_scr;
} ZigSearchJumpPlan;

typedef struct {
	int x;
	int y;
	int scr;
	int len;
} ZigSearchMatch;

typedef struct {
	int x;
	int nmatches;
	int cap;
	int y;
	int scr;
} ZigSearchScanLineState;

typedef struct {
	int kind;
	ZigSearchScanLineState state;
	ZigSearchMatch match;
} ZigSearchScanLineStep;

typedef struct {
	int step_count;
	int steps[4];
} ZigSearchMatchesTransaction;

enum {
	ST_ZIG_SEARCH_APPEND_SKIP = 0,
	ST_ZIG_SEARCH_APPEND = 1,
	ST_ZIG_SEARCH_APPEND_GROW = 2,
};

enum {
	ST_ZIG_SEARCH_MATCHES_STEP_RESET = 1,
	ST_ZIG_SEARCH_MATCHES_STEP_SCAN_VISIBLE = 2,
	ST_ZIG_SEARCH_MATCHES_STEP_SCAN_HISTORY = 3,
	ST_ZIG_SEARCH_MATCHES_STEP_FINALIZE = 4,
};

enum {
	ST_ZIG_SEARCH_CURSOR_NONE = 0,
	ST_ZIG_SEARCH_CURSOR_DELETE = 1,
	ST_ZIG_SEARCH_CURSOR_MOVE = 2,
};

enum {
	ST_ZIG_SEARCH_STATE_NONE = 0,
	ST_ZIG_SEARCH_STATE_CLEAR_INPUT = 1,
	ST_ZIG_SEARCH_STATE_COMMIT_CLEAR = 2,
	ST_ZIG_SEARCH_STATE_COMMIT_SET = 3,
	ST_ZIG_SEARCH_STATE_CANCEL = 4,
};

enum {
	ST_ZIG_SEARCH_CURSOR_ACTION_BACKSPACE = 1,
	ST_ZIG_SEARCH_CURSOR_ACTION_DELETE_FORWARD = 2,
	ST_ZIG_SEARCH_CURSOR_ACTION_DELETE_WORD = 3,
	ST_ZIG_SEARCH_CURSOR_ACTION_MOVE_LEFT = 4,
	ST_ZIG_SEARCH_CURSOR_ACTION_MOVE_RIGHT = 5,
	ST_ZIG_SEARCH_CURSOR_ACTION_HOME = 6,
	ST_ZIG_SEARCH_CURSOR_ACTION_END = 7,
};

enum {
	ST_ZIG_SEARCH_STATE_ACTION_CLEAR_INPUT = 1,
	ST_ZIG_SEARCH_STATE_ACTION_COMMIT = 2,
	ST_ZIG_SEARCH_STATE_ACTION_CANCEL = 3,
};

typedef struct {
	int query_len;
	int inputmode;
	size_t inputlen;
	size_t inputcursor;
	size_t inputcap;
	int nmatches;
	int match_cap;
	int current;
	int active;
} ZigSearchSnapshot;

typedef struct {
	int query_len;
	int active;
	int current;
	int inputmode;
	size_t inputlen;
	size_t inputcursor;
	size_t inputcap;
	int nmatches;
	int match_cap;
} ZigSearchStateUpdate;

typedef struct {
	int alloc_input;
	int realloc_input;
	int alloc_query;
	int realloc_matches;
	int reuse_matches;
	int clear_query;
	int clear_matches;
	int refresh_search;
	int redraw;
	int jump;
} ZigSearchEffectPlan;

typedef struct {
	ZigSearchStateUpdate update;
	ZigSearchEffectPlan effect;
} ZigSearchPromptResult;

typedef struct {
	ZigSearchStateUpdate update;
	ZigSearchEffectPlan effect;
	size_t insert_at;
	size_t move_dst;
	size_t move_src;
	size_t move_len;
} ZigSearchInputResult;

typedef struct {
	ZigSearchStateUpdate update;
	ZigSearchEffectPlan effect;
	ZigSearchInputState input;
	size_t delete_start;
	size_t delete_end;
} ZigSearchCursorResult;

typedef struct {
	ZigSearchStateUpdate update;
	ZigSearchEffectPlan effect;
	ZigSearchInputState input;
} ZigSearchStateResult;

typedef struct {
	ZigSearchStateUpdate update;
	ZigSearchEffectPlan effect;
} ZigSearchScanResult;

typedef struct {
	ZigSearchStateUpdate update;
	ZigSearchEffectPlan effect;
	size_t alloc_len;
} ZigSearchSetResult;

typedef struct {
	int kind;
	int lastpos;
	int newline;
} ZigExternalPipePlan;

typedef struct {
	int kind;
	int scr;
	int histi;
	int histsize;
	int rows;
} ZigTermLineReadSnap;

typedef struct {
	int hist;
	int index;
} ZigTermLineReadPlan;

enum {
	ST_ZIG_TERM_LINE_READ_VIEWPORT_Y = 0,
	ST_ZIG_TERM_LINE_READ_FLAT_HISTORY_Y = 1,
	ST_ZIG_TERM_LINE_READ_RING_OFFSET = 2,
};

enum {
	ST_ZIG_EXTERNALPIPE_BREAK = 0,
	ST_ZIG_EXTERNALPIPE_SKIP = 1,
	ST_ZIG_EXTERNALPIPE_WRITE = 2,
};

enum {
	ST_ZIG_SEL_SCROLL_NONE = 0,
	ST_ZIG_SEL_SCROLL_CLEAR = 1,
	ST_ZIG_SEL_SCROLL_NORMALIZE = 2,
};

enum {
	ST_ZIG_SEL_SNAP_WORD_BREAK = 0,
	ST_ZIG_SEL_SNAP_WORD_ACCEPT = 1,
};

enum {
	ST_ZIG_SEL_SNAP_WORD_ITER_STOP = 0,
	ST_ZIG_SEL_SNAP_WORD_ITER_READ = 1,
};

enum {
	ST_ZIG_SEL_SNAP_LINE_STOP = 0,
	ST_ZIG_SEL_SNAP_LINE_MOVE = 1,
};

enum {
	ST_ZIG_SEARCH_ACTION_NONE = 0,
	ST_ZIG_SEARCH_ACTION_CLEAR = 1,
	ST_ZIG_SEARCH_ACTION_SET = 2,
	ST_ZIG_SEARCH_ACTION_REDRAW = 3,
};

typedef struct {
	int advance;
	int next_x;
	int cursor_state_mask;
	int cursor_state_bits;
} ZigPutcWriteResult;

typedef struct {
	int clear_selection;
	int wrapnext;
	int overflow;
} ZigPutcPreparePlan;

typedef struct {
	ZigStrCollectExec first;
	int retry;
} ZigStrCollectApplyPlan;

typedef struct {
	size_t size;
} ZigStrResetPlan;

enum {
	ST_ZIG_STR_COLLECT_APPEND = 0,
	ST_ZIG_STR_COLLECT_FINISH = 1,
	ST_ZIG_STR_COLLECT_GROW = 2,
	ST_ZIG_STR_COLLECT_ABORT = 3,
};

enum {
	ST_ZIG_STR_COLLECT_STEP_APPLY_FIRST = 1,
	ST_ZIG_STR_COLLECT_STEP_GROW_BUFFER = 2,
	ST_ZIG_STR_COLLECT_STEP_RETRY_COLLECT = 3,
	ST_ZIG_STR_COLLECT_STEP_FINISH = 4,
	ST_ZIG_STR_COLLECT_STEP_ABORT = 5,
};

enum {
	ST_ZIG_ATTR_ERROR_UNKNOWN = 1,
};

enum {
	ST_ZIG_ERASE_OK = 0,
};

enum {
	ST_ZIG_CURSOR_MOVE_TO = 0,
	ST_ZIG_CURSOR_MOVE_TO_ABS = 1,
};

enum {
	ST_ZIG_EDIT_INSERT_BLANK = 0,
	ST_ZIG_EDIT_SCROLL_UP = 1,
	ST_ZIG_EDIT_SCROLL_DOWN = 2,
	ST_ZIG_EDIT_INSERT_BLANK_LINE = 3,
	ST_ZIG_EDIT_DELETE_LINE = 4,
	ST_ZIG_EDIT_CLEAR_REGION = 5,
	ST_ZIG_EDIT_DELETE_CHAR = 6,
};

enum {
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
	ST_ZIG_IO_EFFECT_RAW = 1,
	ST_ZIG_IO_EFFECT_CRLF = 2,
};

enum {
	ST_ZIG_CSI_EXEC_UNKNOWN = 0,
	ST_ZIG_CSI_EXEC_EDIT = 1,
	ST_ZIG_CSI_EXEC_CURSOR = 2,
	ST_ZIG_CSI_EXEC_MISC = 3,
	ST_ZIG_CSI_EXEC_LIGHT = 4,
	ST_ZIG_CSI_EXEC_ERASE = 5,
	ST_ZIG_CSI_EXEC_MODE = 6,
	ST_ZIG_CSI_EXEC_ATTR = 7,
	ST_ZIG_CSI_EXEC_STATE = 8,
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
	ST_ZIG_MOUSE_NONE = 0,
	ST_ZIG_MOUSE_X10 = 1,
	ST_ZIG_MOUSE_BUTTON = 2,
	ST_ZIG_MOUSE_MOTION = 3,
	ST_ZIG_MOUSE_MANY = 4,
	ST_ZIG_MOUSE_SGR = 5,
};

enum {
	ST_ZIG_CURSOR_STATE_NONE = 0,
	ST_ZIG_CURSOR_STATE_ORIGIN = 1,
};

enum {
	ST_ZIG_TERM_MODE_NONE = 0,
	ST_ZIG_TERM_MODE_WRAP = 1,
	ST_ZIG_TERM_MODE_INSERT = 2,
	ST_ZIG_TERM_MODE_ECHO = 3,
	ST_ZIG_TERM_MODE_CRLF = 4,
};

enum {
	ST_ZIG_XSETMODE_NONE = 0,
	ST_ZIG_XSETMODE_HIDE = 1,
	ST_ZIG_XSETMODE_KBDLOCK = 2,
};

enum {
	ST_ZIG_PUTC_ADVANCE_MOVE = 0,
	ST_ZIG_PUTC_ADVANCE_WRAPNEXT = 1,
};

enum {
	ST_ZIG_TERM_CURSOR_MOVE_TO = 0,
	ST_ZIG_TERM_CURSOR_MOVE_TO_ABS = 1,
	ST_ZIG_TERM_CURSOR_NEWLINE = 2,
	ST_ZIG_TERM_CURSOR_REVERSE_INDEX = 3,
	ST_ZIG_TERM_CURSOR_STORE = 4,
};

char *st_base64dec(const char *);
ZigUtf8Decode st_utf8decode(const unsigned char *, size_t);
size_t st_utf8encode(uint32_t, unsigned char *);
ZigCsiParse st_csiparse(const unsigned char *, size_t);
ZigCsiExecPlan st_csiexecplan(char, char, char, const int *, int, int, int, int, int);
ZigMiscPlan st_toggleprinterplan(int);
ZigMiscPlan st_startprinterplan(void);
ZigIoEffectList st_ttywriteeffects(const unsigned char *, size_t, int);
ZigAttrUpdate st_tsetattr(ZigAttrState, uint32_t, uint32_t, const int *, int);
ZigClearRect st_tclearregionrect(int, int, int, int, int, int);
ZigTermCursorPlan st_termcursorplan(int, ZigTermCursorSnapshot, int, int);
ZigBackspacePlan st_backspaceplan(ZigTermCursorSnapshot);
ZigDrawExecPlan st_drawexecplan(ZigTermFrameSnapshot, const ZigGlyph * const *, const int *, int, int);
ZigDrawRegionTransaction st_drawregiontransaction(const int *, int, int);
ZigEditMove st_tdeletechar(int, int, int);
ZigEditMove st_tinsertblank(int, int, int);
ZigScrollPlan st_tscrollplan(int, int, int, int, int, int, int, int);
ZigKScrollPlan st_kscrolldownplan(int, int, int);
ZigKScrollPlan st_kscrollupplan(int, int, int, int);
ZigScrollRegion st_tsetscroll(int, int, int);
ZigResizeExecPlan st_tresizeexecplan(const int *, int, int, int, int, int, int, int);
ZigResetExecPlan st_tresetexecplan(uint32_t, uint32_t, int);
void st_tresettabs(int *, int, unsigned int);
ZigModePlan st_modeplan(int, int, int, int, int);
int st_tdefutf8plan(char, int);
int st_tdeftranplan(char);
ZigStrParse st_strparse(const unsigned char *, size_t);
ZigStrSequence st_tstrsequence(unsigned char, int);
ZigStrHandleParPlan st_strhandleparplan(int);
ZigStrHandlePlan st_strhandleplan(char, int, int, int);
ZigPlatformEffectList st_strapplyplan(int, int, int, int, int);
ZigInputControlPlan st_inputcontrolplan(unsigned char, int, int, int);
ZigInputEscPlan st_inputescplan(unsigned char, int, int, int, int);
ZigPutcDecode st_putcdecode(uint32_t, int);
ZigWriteControlPlan st_twritecontrol(uint32_t, int);
ZigInputStepPlan st_inputstepplan(int, int, int, uint32_t, unsigned char *, size_t, const unsigned char *, size_t, size_t, size_t, size_t, int, int, int, int, int, int, int, int);
void st_tsetchar(uint32_t, const ZigGlyph *, ZigGlyph *, int, int, int);
void st_tclearglyph(ZigGlyph *, int, const ZigGlyph *);
ZigPutcWriteResult st_tputcwrite(uint32_t, int, const ZigGlyph *, ZigGlyph *, int, int, int, int);
ZigStrResetPlan st_strresetplan(void);
int st_tlinelen(const ZigGlyph *, int);
int st_tputtab(int, int, int, const int *);
int st_tattrset(const ZigGlyph * const *, int, int, int);
int st_tlineattrset(const ZigGlyph *, int, int);
ZigDumpLinePlan st_tdumplineplan(int, int);
ZigLineRange st_tsetdirtrange(int, int, int);
int st_selclearplan(int);
ZigSelectionStateResult st_selclearupdate(ZigSelectionSnapshot);
ZigSelectionStateResult st_selstartupdate(ZigSelectionSnapshot, int, int, int, int);
ZigSelectionStateResult st_selextendupdate(ZigSelectionSnapshot, int, int, int, int);
ZigSelectionStateResult st_selscrollupdate(ZigSelectionSnapshot, int, int, int, int);
ZigSelectionStateResult st_selnormalizeupdate(ZigSelectionSnapshot, int, int, int);
int st_selsnaplinex(int, int);
ZigSelSnapLineStep st_selsnaplinestep(int, int, int, int);
ZigSelectionStateUpdate st_selsnapboundsupdate(ZigSelectionSnapshot, int, int, int, int);
ZigSelSnapWordIterRequest st_selsnapworditerrequest(int, int, int, int, int, int, uint32_t);
ZigSelSnapWordStep st_selsnapworditerresolve(ZigSelSnapWordIterRequest, int, uint32_t, ZigSelSnapWordReaderSnapshot);
int st_selected(ZigSelectionSnapshot, int, int, int);
int st_searchmatchlist(const ZigSearchMatch *, int, int, int, int, int, int);
int st_searchcurrentmatch(const ZigSearchMatch *, int, int, int, int, int, int);
ZigSearchScanLineStep st_searchscanlineiter(const ZigGlyph *, int, const uint32_t *, int, ZigSearchScanLineState);
ZigSearchMatchesTransaction st_searchmatchestransaction(int, int);
ZigTermLineReadPlan st_termlinereadplan(ZigTermLineReadSnap, int);
ZigSearchStepPlan st_searchstep(int, int, int, int);
ZigSearchJumpPlan st_searchjumpplan(int, int, int, int, int);
ZigSearchCursorResult st_searchcursorupdate(ZigSearchSnapshot, const unsigned char *, int);
ZigSearchStateResult st_searchstateupdate(ZigSearchSnapshot, int);
ZigSearchScanResult st_searchscanupdate(ZigSearchSnapshot, int, int);
ZigExternalPipePlan st_externalpipeplan(const ZigGlyph *, int);
ZigSearchPromptResult st_searchpromptupdate(ZigSearchSnapshot);
ZigSearchInputResult st_searchinputupdate(ZigSearchSnapshot, size_t);
ZigSearchSetResult st_searchsetupdate(ZigSearchSnapshot, size_t, int);
ZigGetSelExecPlan st_getselexecplan(ZigSelectionSnapshot, int, int, const ZigGlyph *, int);
ZigSelectionExtractTransaction st_selectionextracttransaction(ZigSelectionSnapshot, int, int);

#endif
