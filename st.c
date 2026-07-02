/* See LICENSE for license details. */
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pwd.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <wchar.h>

#include "st.h"
#include "st_zig.h"
#include "win.h"

#if defined(__linux)
#include <pty.h>
#elif defined(__OpenBSD__) || defined(__NetBSD__) || defined(__APPLE__)
#include <util.h>
#elif defined(__FreeBSD__) || defined(__DragonFly__)
#include <libutil.h>
#endif

/* Arbitrary sizes */
#define UTF_INVALID 0xFFFD
#define UTF_SIZ 4
#define ESC_BUF_SIZ (128 * UTF_SIZ)
#define ESC_ARG_SIZ 16
#define STR_BUF_SIZ ST_ZIG_STR_BUF_SIZ
#define STR_ARG_SIZ ESC_ARG_SIZ
#define HISTSIZE 2000

/* macros */
#define IS_SET(flag) ((term.mode & (flag)) != 0)
#define ISCONTROLC0(c) (BETWEEN(c, 0, 0x1f) || (c) == 0x7f)
#define ISCONTROLC1(c) (BETWEEN(c, 0x80, 0x9f))
#define ISCONTROL(c) (ISCONTROLC0(c) || ISCONTROLC1(c))
#define ISDELIM(u) (u && wcschr(worddelimiters, u))
#define TLINE(y)                                                                                                       \
    ((y) < term.scr ? term.hist[(int)((((y) + term.histi - term.scr + HISTSIZE + 1) % HISTSIZE))]                      \
                    : term.line[(y) - term.scr])

enum term_mode {
    MODE_WRAP = 1 << 0,
    MODE_INSERT = 1 << 1,
    MODE_ALTSCREEN = 1 << 2,
    MODE_CRLF = 1 << 3,
    MODE_ECHO = 1 << 4,
    MODE_PRINT = 1 << 5,
    MODE_UTF8 = 1 << 6,
};

enum cursor_movement { CURSOR_SAVE, CURSOR_LOAD };

enum cursor_state { CURSOR_DEFAULT = 0, CURSOR_WRAPNEXT = 1, CURSOR_ORIGIN = 2 };

enum charset { CS_GRAPHIC0, CS_GRAPHIC1, CS_UK, CS_USA, CS_MULTI, CS_GER, CS_FIN };

enum escape_state {
    ESC_START = 1,
    ESC_CSI = 2,
    ESC_STR = 4, /* DCS, OSC, PM, APC */
    ESC_ALTCHARSET = 8,
    ESC_STR_END = 16, /* a final string was encountered */
    ESC_TEST = 32,    /* Enter in test mode */
    ESC_UTF8 = 64,
};

typedef struct {
    Glyph attr; /* current char attributes */
    int x;
    int y;
    char state;
} TCursor;

typedef struct {
    int mode;
    int type;
    int snap;
    /*
     * Selection variables:
     * nb – normalized coordinates of the beginning of the selection
     * ne – normalized coordinates of the end of the selection
     * ob – original coordinates of the beginning of the selection
     * oe – original coordinates of the end of the selection
     */
    struct {
        int x, y;
    } nb, ne, ob, oe;

    int alt;
} Selection;

/* Internal representation of the screen */
typedef struct {
    int row; /* nb row */
    int col; /* nb col */
    int maxcol;
    Line *line;          /* screen */
    Line *alt;           /* alternate screen */
    Line hist[HISTSIZE]; /* history buffer */
    int histi;           /* history index */
    int scr;             /* scroll back */
    int *dirty;          /* dirtyness of lines */
    TCursor c;           /* cursor */
    int ocx;             /* old cursor col */
    int ocy;             /* old cursor row */
    int top;             /* top    scroll limit */
    int bot;             /* bottom scroll limit */
    int mode;            /* terminal mode flags */
    int esc;             /* escape state flags */
    char trantbl[4];     /* charset table translation */
    int charset;         /* current charset */
    int icharset;        /* selected charset for sequence */
    int *tabs;
    Rune lastc; /* last printed char outside of sequence, 0 if control */
} Term;

typedef struct {
    int set_cursor;
    TCursor cursor;
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
} TermStateUpdate;

/* CSI Escape sequence structs */
/* ESC '[' [[ [<priv>] <arg> [;]] <mode> [<mode>]] */
typedef struct {
    char buf[ESC_BUF_SIZ]; /* raw string */
    size_t len;            /* raw string length */
    char priv;
    int arg[ESC_ARG_SIZ];
    int narg; /* nb of args */
    char mode[2];
} CSIEscape;

/* STR Escape sequence structs */
/* ESC type [[ [<priv>] <arg> [;]] <mode>] ESC '\' */
typedef struct {
    char type;  /* ESC type ... */
    char *buf;  /* allocated raw string */
    size_t siz; /* allocation size */
    size_t len; /* raw string length */
    char *args[STR_ARG_SIZ];
    int narg; /* nb of args */
} STREscape;

typedef struct {
    int x;
    int y;
    int scr;
    int len;
} SearchMatch;

typedef struct {
    Rune *query;
    int qlen;
    char *input;
    size_t inputlen;
    size_t inputcursor;
    size_t inputcap;
    SearchMatch *matches;
    int nmatches;
    int cap;
    int current;
    int active;
    int inputmode;
} SearchState;

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
} SearchScalarState;

typedef struct {
    int count;
    int cap;
} SearchMatchesState;

typedef struct {
    size_t input_cap;
    size_t input_len;
    int realloc_input;
    int clear;
    size_t insert_at;
    size_t move_dst;
    size_t move_src;
    size_t move_len;
    const char *insert_text;
    size_t insert_len;
} SearchInputTransaction;

typedef struct {
    int x;
    int y;
} SelectionSnapPoint;

typedef struct {
    int kind;
    int arg;
    int index_arg;
} PlatformEffect;

typedef struct {
    int count;
    PlatformEffect effects[8];
} PlatformEffectList;

static void execsh(char *, char **);
static void stty(char **);
static void sigchld(int);
static void ttywriteraw(const char *, size_t);
static SearchScalarState searchscalarstate(void);
static void searchwritescalarstate(SearchScalarState);
static ZigSearchSnapshot zigsearchsnapshot(SearchScalarState);
static SearchScalarState searchscalarfromupdate(ZigSearchStateUpdate);
static ZigSearchInputState searchinputstate(void);
static void searchapplyquerytransaction(const char *);
static void searchapplyqueryreplace(Rune *, ZigSearchSetResult);
static SearchMatchesState searchmatchesstate(void);
static void searchwritematchesstate(SearchMatchesState);
static void searchapplyinputinsert(ZigSearchInputResult, const char *, size_t);
static void searchapplyinputclear(ZigSearchStateResult);
static void searchapplyinputtransaction(SearchInputTransaction);

static void csidump(void);
static void csihandle(void);
static void csiparse(void);
static void csireset(void);
static int eschandle(uchar);
static void strdump(void);
static void strhandle(void);
static void strapplyplan(const ZigStrHandlePlan *, int);
static void platformapplyeffects(const PlatformEffectList *, const ZigStrHandlePlan *, int);
static char *strarg(const ZigStrHandlePlan *, int, int, const char *);
static char *strargpar(int, int);
static void strparse(void);
static void strreset(void);

static void tprinter(char *, size_t);
static void tdumpsel(void);
static void tdumpline(int);
static void tdump(void);
static void tapplymisc(const ZigMiscPlan *);
static void tclearregion(int, int, int, int);
static void tcursor(int);
static void tdeletechar(int);
static void tdeleteline(int);
static void tinsertblank(int);
static void tinsertblankline(int);
static int tlinelen(int);
static Line tlinehist(int);
static void tmoveto(int, int);
static void tmoveato(int, int);
static void tnewline(int);
static void tputtab(int);
static void tputc(Rune);
static void treset(void);
static void tscrollup(int, int, int);
static void tscrolldown(int, int, int);
static void tapplyscrollplan(const ZigScrollPlan *, int);
static void tsetattr(int *, int);
static void tsetchar(Rune, Glyph *, int, int);
static void tsetdirt(int, int);
static void termapplydirtyrange(ZigLineRange);
static void termapplycursorplan(const ZigTermCursorPlan *);
static void termapplystateupdate(TermStateUpdate);
static void termapplyresetstate(const ZigResetPlan *);
static void tsetscroll(int, int);
static void tswapscreen(void);
static void tsetmode(int, int, int *, int);
static int twrite(const char *, int, int);
static void tcontrolcode(uchar);
static void tdectest(char);
static void tdefutf8(char);
static void tdeftran(char);
static void tstrsequence(uchar);

static void drawregion(int, int, int, int);

static void searchscan(void);
static void searchset(const char *);
static void searchscanline(Line, int, int);
static Line searchhistline(int);
static ZigSearchSnapshot searchsnapshot(void);
static void searchapplyupdate(ZigSearchStateUpdate);
static void searchapplyresourceeffect(ZigSearchEffectPlan);
static void searchapplyvieweffect(ZigSearchEffectPlan);
static void searchapplyfloweffect(ZigSearchEffectPlan);
static int searchresetscanmatches(void);
static void searchresetstate(void);
static void searchapplycursor(int);
static void searchapplystate(int);
static void searchjump(void);
static size_t searchprevchar(size_t);
static size_t searchnextchar(size_t);

static ZigSelectionSnapshot selectionsnapshot(void);
static void selectionapplystate(ZigSelectionStateUpdate);
static void selectionapplybounds(ZigSelectionStateUpdate);
static void selectionapplyresult(ZigSelectionStateResult);
static void selectionapplyscrollresult(ZigSelectionStateResult);

static void selnormalize(void);
static void selscroll(int, int);
static SelectionSnapPoint selsnappoint(int, int, int);

static size_t utf8decode(const char *, Rune *, size_t);

static char *base64dec(const char *);

static ssize_t xwrite(int, const char *, size_t);

/* Globals */
static Term term;
static Selection sel;
static CSIEscape csiescseq;
static STREscape strescseq;
static SearchState search;
static int iofd = 1;
static int cmdfd;
static pid_t pid;

ssize_t xwrite(int fd, const char *s, size_t len) {
    size_t aux = len;
    ssize_t r;

    while (len > 0) {
        r = write(fd, s, len);
        if (r < 0)
            return r;
        len -= r;
        s += r;
    }

    return aux;
}

void *xmalloc(size_t len) {
    void *p;

    if (!(p = malloc(len)))
        die("malloc: %s\n", strerror(errno));

    return p;
}

void *xrealloc(void *p, size_t len) {
    if ((p = realloc(p, len)) == NULL)
        die("realloc: %s\n", strerror(errno));

    return p;
}

char *xstrdup(char *s) {
    if ((s = strdup(s)) == NULL)
        die("strdup: %s\n", strerror(errno));

    return s;
}

size_t utf8decode(const char *c, Rune *u, size_t clen) {
    ZigUtf8Decode dec;

    dec = st_utf8decode((const unsigned char *)c, clen);
    *u = dec.rune;
    return dec.len;
}

size_t utf8encode(Rune u, char *c) { return st_utf8encode(u, (unsigned char *)c); }

char *base64dec(const char *src) { return st_base64dec(src); }

void selinit(void) {
    sel.mode = SEL_IDLE;
    sel.snap = 0;
    sel.ob.x = -1;
}

int tlinelen(int y) { return st_tlinelen((const ZigGlyph *)TLINE(y), term.col); }

Line tlinehist(int y) {
    ZigHistoryLinePlan plan;

    plan = st_tlinehistplan(y, HISTSIZE, term.row);
    return plan.hist ? term.hist[plan.index] : term.line[plan.index];
}

void selstart(int col, int row, int snap) {
    ZigSelectionStateResult result;

    selclear();
    result = st_selstartupdate(selectionsnapshot(), col, row, snap, IS_SET(MODE_ALTSCREEN));
    selectionapplyresult(result);
}

void selextend(int col, int row, int type, int done) {
    ZigSelectionStateResult result;

    if (sel.mode == SEL_IDLE)
        return;
    if (done && sel.mode == SEL_EMPTY) {
        selclear();
        return;
    }
    result = st_selextendupdate(selectionsnapshot(), col, row, type, done);
    selectionapplyresult(result);
}

void selnormalize(void) {
    ZigSelectionStateResult result;
    int start_len, end_len;

    start_len = tlinelen(sel.ob.y < sel.oe.y ? sel.ob.y : sel.oe.y);
    end_len = tlinelen(sel.ob.y < sel.oe.y ? sel.oe.y : sel.ob.y);
    result = st_selnormalizeupdate(selectionsnapshot(), term.col, start_len, end_len);
    selectionapplybounds(result.update);

    {
        SelectionSnapPoint nb = selsnappoint(sel.nb.x, sel.nb.y, -1);
        SelectionSnapPoint ne = selsnappoint(sel.ne.x, sel.ne.y, +1);
        selectionapplybounds(st_selsnapboundsupdate(selectionsnapshot(), nb.x, nb.y, ne.x, ne.y));
    }
}

static ZigSelectionSnapshot selectionsnapshot(void) {
    return (ZigSelectionSnapshot){
        .mode = sel.mode,
        .selection_type = sel.type,
        .alt = sel.alt,
        .snap = sel.snap,
        .ob_x = sel.ob.x,
        .ob_y = sel.ob.y,
        .oe_x = sel.oe.x,
        .oe_y = sel.oe.y,
        .nb_x = sel.nb.x,
        .nb_y = sel.nb.y,
        .ne_x = sel.ne.x,
        .ne_y = sel.ne.y,
    };
}

static void selectionapplystate(ZigSelectionStateUpdate update) {
    sel.mode = update.mode;
    sel.type = update.selection_type;
    sel.alt = update.alt;
    sel.snap = update.snap;
    sel.ob.x = update.ob_x;
    sel.ob.y = update.ob_y;
    sel.oe.x = update.oe_x;
    sel.oe.y = update.oe_y;
    selectionapplybounds(update);
}

static void selectionapplybounds(ZigSelectionStateUpdate update) {
    sel.nb.x = update.nb_x;
    sel.nb.y = update.nb_y;
    sel.ne.x = update.ne_x;
    sel.ne.y = update.ne_y;
}

static void selectionapplyresult(ZigSelectionStateResult result) {
    selectionapplystate(result.update);
    if (result.effect.dirty)
        tsetdirt(result.effect.top, result.effect.bot);
}

static void selectionapplyscrollresult(ZigSelectionStateResult result) {
    if (result.effect.clear)
        selclear();
    else
        selectionapplystate(result.update);
}

int selected(int x, int y) { return st_selected(selectionsnapshot(), x, y, IS_SET(MODE_ALTSCREEN)); }

int searchmatch(int x, int y) {
    SearchMatchesState matches;
    SearchScalarState state;

    state = searchscalarstate();
    matches = searchmatchesstate();
    return st_searchmatchlist((const ZigSearchMatch *)search.matches, matches.count, state.active, state.current,
                              term.scr, x, y);
}

int searchcurrent(int x, int y) {
    SearchMatchesState matches;
    SearchScalarState state;

    state = searchscalarstate();
    matches = searchmatchesstate();
    return st_searchcurrentmatch((const ZigSearchMatch *)search.matches, matches.count, state.active, state.current,
                                 term.scr, x, y);
}

void searchclear(const Arg *arg) {
    (void)arg;
    searchresetstate();
    redraw();
}

int searchinputactive(void) { return searchscalarstate().inputmode; }

int searchbaractive(void) {
    SearchScalarState state;

    state = searchscalarstate();
    return state.inputmode || state.active;
}

const char *searchinputtext(void) { return search.input ? search.input : ""; }

size_t searchinputcursor(void) { return searchscalarstate().inputcursor; }

void searchnext(const Arg *arg) {
    SearchMatchesState matches;
    SearchScalarState state;
    ZigSearchStepPlan plan;

    (void)arg;
    searchscan();
    state = searchscalarstate();
    matches = searchmatchesstate();
    plan = st_searchstep(state.active, matches.count, state.current, 1);
    if (!plan.run)
        return;
    state.current = plan.current;
    searchwritescalarstate(state);
    searchjump();
    redraw();
}

void searchprev(const Arg *arg) {
    SearchMatchesState matches;
    SearchScalarState state;
    ZigSearchStepPlan plan;

    (void)arg;
    searchscan();
    state = searchscalarstate();
    matches = searchmatchesstate();
    plan = st_searchstep(state.active, matches.count, state.current, -1);
    if (!plan.run)
        return;
    state.current = plan.current;
    searchwritescalarstate(state);
    searchjump();
    redraw();
}

void searchprompt(const Arg *arg) {
    ZigSearchInputState input;
    ZigSearchPromptResult result;

    (void)arg;
    result = st_searchpromptupdate(searchsnapshot());
    searchapplyupdate(result.update);
    input = searchinputstate();
    if (result.effect.alloc_input) {
        search.input = xmalloc(input.cap);
    }
    if (!search.input)
        die("searchprompt: input buffer is NULL after alloc check inputcap=%zu alloc_input=%d\n", input.cap,
            result.effect.alloc_input);
    search.input[0] = '\0';
    searchapplyvieweffect(result.effect);
}

void searchinput(const char *text, size_t len) {
    ZigSearchInputResult result;

    result = st_searchinputupdate(searchsnapshot(), len);
    if (!result.effect.refresh_search)
        return;
    searchapplyinputinsert(result, text, len);
}

void searchbackspace(void) { searchapplycursor(ST_ZIG_SEARCH_CURSOR_ACTION_BACKSPACE); }

void searchdeleteforward(void) { searchapplycursor(ST_ZIG_SEARCH_CURSOR_ACTION_DELETE_FORWARD); }

void searchdeleteword(void) { searchapplycursor(ST_ZIG_SEARCH_CURSOR_ACTION_DELETE_WORD); }

void searchclearinput(void) { searchapplystate(ST_ZIG_SEARCH_STATE_ACTION_CLEAR_INPUT); }

void searchmoveleft(void) { searchapplycursor(ST_ZIG_SEARCH_CURSOR_ACTION_MOVE_LEFT); }

void searchmoveright(void) { searchapplycursor(ST_ZIG_SEARCH_CURSOR_ACTION_MOVE_RIGHT); }

void searchhome(void) { searchapplycursor(ST_ZIG_SEARCH_CURSOR_ACTION_HOME); }

void searchend(void) { searchapplycursor(ST_ZIG_SEARCH_CURSOR_ACTION_END); }

static ZigSearchSnapshot zigsearchsnapshot(SearchScalarState state) {
    return (ZigSearchSnapshot){
        .query_len = state.query_len,
        .inputmode = state.inputmode,
        .inputlen = state.inputlen,
        .inputcursor = state.inputcursor,
        .inputcap = state.inputcap,
        .nmatches = state.nmatches,
        .match_cap = state.match_cap,
        .current = state.current,
        .active = state.active,
    };
}

static void searchwritescalarstate(SearchScalarState state) {
    search.qlen = state.query_len;
    search.active = state.active;
    search.current = state.current;
    search.inputmode = state.inputmode;
    search.inputlen = state.inputlen;
    search.inputcursor = state.inputcursor;
    search.inputcap = state.inputcap;
    search.nmatches = state.nmatches;
    search.cap = state.match_cap;
}

static SearchScalarState searchscalarstate(void) {
    return (SearchScalarState){
        .query_len = search.qlen,
        .active = search.active,
        .current = search.current,
        .inputmode = search.inputmode,
        .inputlen = search.inputlen,
        .inputcursor = search.inputcursor,
        .inputcap = search.inputcap,
        .nmatches = search.nmatches,
        .match_cap = search.cap,
    };
}

static SearchScalarState searchscalarfromupdate(ZigSearchStateUpdate update) {
    return (SearchScalarState){
        .query_len = update.query_len,
        .active = update.active,
        .current = update.current,
        .inputmode = update.inputmode,
        .inputlen = update.inputlen,
        .inputcursor = update.inputcursor,
        .inputcap = update.inputcap,
        .nmatches = update.nmatches,
        .match_cap = update.match_cap,
    };
}

static ZigSearchInputState searchinputstate(void) {
    return (ZigSearchInputState){
        .active = search.inputmode,
        .len = search.inputlen,
        .cursor = search.inputcursor,
        .cap = search.inputcap,
    };
}

static SearchMatchesState searchmatchesstate(void) {
    return (SearchMatchesState){
        .count = search.nmatches,
        .cap = search.cap,
    };
}

static void searchwritematchesstate(SearchMatchesState state) {
    search.nmatches = state.count;
    search.cap = state.cap;
}

static ZigSearchSnapshot searchsnapshot(void) { return zigsearchsnapshot(searchscalarstate()); }

static void searchapplyupdate(ZigSearchStateUpdate update) { searchwritescalarstate(searchscalarfromupdate(update)); }

static void searchapplyresourceeffect(ZigSearchEffectPlan effect) {
    if (effect.clear_query) {
        free(search.query);
        search.query = NULL;
    }
    if (effect.clear_matches) {
        free(search.matches);
        search.matches = NULL;
    }
}

static void searchapplyvieweffect(ZigSearchEffectPlan effect) {
    if (effect.jump)
        searchjump();
    if (effect.redraw)
        redraw();
}

static void searchapplyfloweffect(ZigSearchEffectPlan effect) {
    if (effect.refresh_search)
        searchset(search.input ? search.input : "");
    else
        searchapplyvieweffect(effect);
}

static int searchresetscanmatches(void) {
    SearchMatchesState matches;
    SearchScalarState state;

    state = searchscalarstate();
    matches = searchmatchesstate();
    if (search.matches && matches.cap > 0)
        matches.count = 0;
    matches.count = 0;
    searchwritematchesstate(matches);
    return state.current;
}

static void searchapplyqueryreplace(Rune *runes, ZigSearchSetResult result) {
    /* query 指针本体仍由 C 持有，但替换时序收口到单一 helper，
     * 避免 searchset() 同时展开 free/replace/scan/jump 的细节。 */
    searchapplyresourceeffect(result.effect);
    search.query = runes;
    searchapplyupdate(result.update);
    if (result.effect.refresh_search)
        searchscan();
    searchapplyvieweffect(result.effect);
}

static void searchapplyquerytransaction(const char *query) {
    Rune rune;
    size_t off, query_len, step;
    int qlen;
    Rune *runes;
    ZigSearchSetResult result;

    query_len = strlen(query);
    result = st_searchsetupdate(searchsnapshot(), query_len, 0);
    runes = xmalloc(result.alloc_len * sizeof(Rune));

    qlen = 0;
    for (off = 0; off < query_len; off += step) {
        step = utf8decode(query + off, &rune, query_len - off);
        if (step == 0)
            break;
        runes[qlen++] = rune;
    }
    result = st_searchsetupdate(searchsnapshot(), query_len, qlen);
    searchapplyqueryreplace(runes, result);
}

static void searchapplyinputinsert(ZigSearchInputResult result, const char *text, size_t len) {
    SearchInputTransaction transaction;

    searchapplyupdate(result.update);
    transaction = (SearchInputTransaction){
        .input_cap = result.update.inputcap,
        .input_len = result.update.inputlen,
        .realloc_input = result.effect.realloc_input,
        .move_dst = result.move_dst,
        .move_src = result.move_src,
        .move_len = result.move_len,
        .insert_at = result.insert_at,
        .insert_text = text,
        .insert_len = len,
    };
    searchapplyinputtransaction(transaction);
    searchset(search.input);
}

static void searchapplyinputclear(ZigSearchStateResult result) {
    SearchInputTransaction transaction;

    searchapplyupdate(result.update);
    searchapplyresourceeffect(result.effect);
    transaction = (SearchInputTransaction){
        .input_cap = result.input.cap,
        .input_len = result.input.len,
        .clear = 1,
    };
    searchapplyinputtransaction(transaction);
    if (result.effect.clear_query && result.input.cap == 0) {
        free(search.input);
        search.input = NULL;
    }
    searchapplyfloweffect(result.effect);
}

static void searchapplyinputtransaction(SearchInputTransaction transaction) {
    if (transaction.realloc_input)
        search.input = xrealloc(search.input, transaction.input_cap);
    if (transaction.move_len > 0)
        memmove(search.input + transaction.move_dst, search.input + transaction.move_src, transaction.move_len);
    if (transaction.insert_len > 0)
        memcpy(search.input + transaction.insert_at, transaction.insert_text, transaction.insert_len);
    if (transaction.clear && search.input && transaction.input_len == 0)
        search.input[0] = '\0';
    if (transaction.insert_len > 0)
        search.input[transaction.input_len] = '\0';
}

static void searchresetstate(void) {
    free(search.query);
    free(search.input);
    free(search.matches);
    memset(&search, 0, sizeof(search));
    search.current = -1;
}

static void searchapplycursor(int action) {
    ZigSearchCursorResult result;
    ZigSearchInputState input;
    SearchInputTransaction transaction;

    result = st_searchcursorupdate(searchsnapshot(), (const unsigned char *)searchinputtext(), action);
    if (result.delete_start != result.delete_end) {
        input = searchinputstate();
        transaction = (SearchInputTransaction){
            .input_cap = result.input.cap,
            .input_len = result.input.len,
            .move_dst = result.delete_start,
            .move_src = result.delete_end,
            .move_len = input.len - result.delete_end + 1,
        };
        searchapplyinputtransaction(transaction);
    }
    searchapplyupdate(result.update);
    searchapplyfloweffect(result.effect);
}

size_t searchprevchar(size_t cursor) {
    ZigSearchInputState input;
    size_t next;

    input = searchinputstate();
    if (cursor == 0)
        return 0;
    next = cursor - 1;
    while (next > 0 && (((unsigned char)search.input[next] & 0xc0) == 0x80))
        next--;
    if (next > input.len)
        return input.len;
    return next;
}

size_t searchnextchar(size_t cursor) {
    ZigSearchInputState input;
    size_t next;

    input = searchinputstate();
    if (cursor >= input.len)
        return input.len;
    next = cursor + 1;
    while (next < input.len && (((unsigned char)search.input[next] & 0xc0) == 0x80))
        next++;
    return next;
}

void searchcommit(void) { searchapplystate(ST_ZIG_SEARCH_STATE_ACTION_COMMIT); }

void searchcancel(void) { searchapplystate(ST_ZIG_SEARCH_STATE_ACTION_CANCEL); }

static void searchapplystate(int action) {
    ZigSearchStateResult result;

    result = st_searchstateupdate(searchsnapshot(), action);
    searchapplyinputclear(result);
}

void searchset(const char *query) {
    searchapplyquerytransaction(query);
}

void searchscan(void) {
    int y, scr, oldcurrent;
    SearchMatchesState matches;
    SearchScalarState state;
    ZigSearchScanResult result;

    /* scan 会重建整份 matches 数组。
     * 先记住旧 current，扫描结束后再决定保留旧索引、回退到 0，还是置为 -1。 */
    state = searchscalarstate();
    oldcurrent = searchresetscanmatches();
    if (!state.active || state.query_len <= 0)
        return;

    for (y = 0; y < term.row; ++y) {
        searchscanline(term.line[y], 0, y);
    }
    for (scr = 1; scr < HISTSIZE; ++scr) {
        searchscanline(searchhistline(scr), scr, 0);
    }

    /* matches 重新生成后的 current/nmatches 收口也交给 Zig，
     * C 只保留数组写入和最终状态落回。 */
    matches = searchmatchesstate();
    result = st_searchscanupdate(searchsnapshot(), matches.count, oldcurrent);
    searchapplyresourceeffect(result.effect);
    searchapplyupdate(result.update);
}

void searchscanline(Line line, int scr, int y) {
    int x;
    SearchMatchesState matches;
    SearchScalarState state;
    SearchMatch *match;
    ZigSearchScanLineState scanstate;
    ZigSearchScanLineStep step;

    matches = searchmatchesstate();
    state = searchscalarstate();
    scanstate = (ZigSearchScanLineState){
        .x = 0,
        .nmatches = matches.count,
        .cap = matches.cap,
        .y = y,
        .scr = scr,
    };
    /* Zig 持有 scan line iterator state 和 append/grow/stop 决策。
     * C 只执行真实扩容与 SearchMatch 数组写入。 */
    for (;;) {
        x = scanstate.nmatches;
        step = st_searchscanlineiter((const ZigGlyph *)line, term.col, search.query, state.query_len, scanstate);
        if (step.kind == ST_ZIG_SEARCH_APPEND_SKIP)
            break;

        if (step.kind == ST_ZIG_SEARCH_APPEND_GROW) {
            matches.cap = step.state.cap;
            searchwritematchesstate(matches);
            search.matches = xrealloc(search.matches, matches.cap * sizeof(*search.matches));
        }
        match = &search.matches[x];
        match->x = step.match.x;
        match->y = step.match.y;
        match->scr = step.match.scr;
        match->len = step.match.len;
        matches.count = step.state.nmatches;
        searchwritematchesstate(matches);
        scanstate = step.state;
    }
}

Line searchhistline(int scr) { return term.hist[(int)(((term.histi - scr + HISTSIZE + 1) % HISTSIZE))]; }

void searchjump(void) {
    SearchMatch *match;
    SearchMatchesState matches;
    SearchScalarState state;
    ZigSearchJumpPlan plan;

    /* jump 不负责重算匹配，只消费当前 search.current。
     * 如果当前匹配在不同的 scrollback 层，就把 term.scr 切过去并整体标脏。 */
    matches = searchmatchesstate();
    state = searchscalarstate();
    if (!state.active || state.current < 0 || state.current >= matches.count)
        return;

    match = &search.matches[state.current];
    plan = st_searchjumpplan(state.active, state.current, matches.count, term.scr, match->scr);
    if (plan.run && term.scr != plan.new_scr) {
        term.scr = plan.new_scr;
        tfulldirt();
    }
}

SelectionSnapPoint selsnappoint(int x, int y, int direction) {
    int delim, prevdelim, linelen, wrap_allowed;
    Rune rune, prevrune;
    Glyph *gp;
    ZigSelSnapWordIterRequest word_request;
    ZigSelSnapWordStep word_step;
    ZigSelSnapWordReaderSnapshot word_reader;
    ZigSelSnapLineStep line_step;

    switch (sel.snap) {
    case SNAP_WORD:
        /*
         * Snap around if the word wraps around at the end or
         * beginning of a line.
         */
        prevrune = TLINE(y)[x].u;
        prevdelim = ISDELIM(prevrune);
        for (;;) {
            word_request = st_selsnapworditerrequest(x, y, direction, term.col, term.row, prevdelim, prevrune);
            if (word_request.action == ST_ZIG_SEL_SNAP_WORD_ITER_STOP)
                break;

            wrap_allowed = !word_request.wrapped || (TLINE(word_request.wrap_y)[word_request.wrap_x].mode & ATTR_WRAP);
            gp = &TLINE(word_request.y)[word_request.x];
            delim = ISDELIM(gp->u);
            linelen = tlinelen(word_request.y);
            rune = gp->u;
            word_reader = (ZigSelSnapWordReaderSnapshot){
                .wrap_allowed = wrap_allowed,
                .linelen = linelen,
                .mode = gp->mode,
                .delim = delim,
                .rune = rune,
            };
            word_step = st_selsnapworditerresolve(word_request, prevdelim, prevrune, word_reader);
            if (word_step.action == ST_ZIG_SEL_SNAP_WORD_BREAK)
                break;

            x = word_step.x;
            y = word_step.y;
            prevdelim = word_step.prevdelim;
            prevrune = word_step.prevrune;
        }
        break;
    case SNAP_LINE:
        /*
         * Snap around if the the previous line or the current one
         * has set ATTR_WRAP at its end. Then the whole next or
         * previous line will be selected.
         */
        x = st_selsnaplinex(direction, term.col);
        if (direction < 0) {
            for (;;) {
                line_step = st_selsnaplinestep(y, direction, term.row,
                                               y > 0 && (TLINE(y - 1)[term.col - 1].mode & ATTR_WRAP));
                if (line_step.action == ST_ZIG_SEL_SNAP_LINE_STOP)
                    break;
                y = line_step.y;
            }
        } else if (direction > 0) {
            for (;;) {
                line_step = st_selsnaplinestep(y, direction, term.row,
                                               y < term.row - 1 && (TLINE(y)[term.col - 1].mode & ATTR_WRAP));
                if (line_step.action == ST_ZIG_SEL_SNAP_LINE_STOP)
                    break;
                y = line_step.y;
            }
        }
        break;
    }
    return (SelectionSnapPoint){.x = x, .y = y};
}

char *getsel(void) {
    char *str, *ptr;
    int y;
    Glyph *gp, *last;
    ZigGetSelExecPlan plan;

    if (sel.ob.x == -1)
        return NULL;

    plan = st_getselexecplan(selectionsnapshot(), sel.nb.y, term.col, (const ZigGlyph *)TLINE(sel.nb.y), UTF_SIZ);
    ptr = str = xmalloc(plan.bufsize);

    /* append every set & selected glyph to the selection */
    for (y = sel.nb.y; y <= sel.ne.y; y++) {
        plan = st_getselexecplan(selectionsnapshot(), y, term.col, (const ZigGlyph *)TLINE(y), UTF_SIZ);
        if (plan.empty) {
            *ptr++ = '\n';
            continue;
        }

        gp = &TLINE(y)[plan.start_x];
        last = &TLINE(y)[plan.last_index];

        for (; gp <= last; ++gp) {
            if (gp->mode & ATTR_WDUMMY)
                continue;

            ptr += utf8encode(gp->u, ptr);
        }

        /*
         * Copy and pasting of line endings is inconsistent
         * in the inconsistent terminal and GUI world.
         * The best solution seems like to produce '\n' when
         * something is copied from st and convert '\n' to
         * '\r', when something to be pasted is received by
         * st.
         * FIXME: Fix the computer world.
         */
        if (plan.newline)
            *ptr++ = '\n';
    }
    *ptr = 0;
    return str;
}

void selclear(void) {
    ZigSelectionStateResult result;

    if (!st_selclearplan(sel.ob.x))
        return;
    result = st_selclearupdate(selectionsnapshot());
    selectionapplyresult(result);
}

void die(const char *errstr, ...) {
    va_list ap;

    va_start(ap, errstr);
    vfprintf(stderr, errstr, ap);
    va_end(ap);
    exit(1);
}

void execsh(char *cmd, char **args) {
    char *sh, *prog, *arg;
    const struct passwd *pw;

    errno = 0;
    if ((pw = getpwuid(getuid())) == NULL) {
        if (errno)
            die("getpwuid: %s\n", strerror(errno));
        else
            die("who are you?\n");
    }

    if ((sh = getenv("SHELL")) == NULL)
        sh = (pw->pw_shell[0]) ? pw->pw_shell : cmd;

    if (args) {
        prog = args[0];
        arg = NULL;
    } else if (scroll) {
        prog = scroll;
        arg = utmp ? utmp : sh;
    } else if (utmp) {
        prog = utmp;
        arg = NULL;
    } else {
        prog = sh;
        arg = NULL;
    }
    DEFAULT(args, ((char *[]){prog, arg, NULL}));

    unsetenv("COLUMNS");
    unsetenv("LINES");
    unsetenv("TERMCAP");
    setenv("LOGNAME", pw->pw_name, 1);
    setenv("USER", pw->pw_name, 1);
    setenv("SHELL", sh, 1);
    setenv("HOME", pw->pw_dir, 1);
    setenv("TERM", termname, 1);

    signal(SIGCHLD, SIG_DFL);
    signal(SIGHUP, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    signal(SIGQUIT, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    signal(SIGALRM, SIG_DFL);

    execvp(prog, args);
    _exit(1);
}

void sigchld(int a) {
    int stat;
    pid_t p;

    if ((p = waitpid(pid, &stat, WNOHANG)) < 0)
        die("waiting for pid %hd failed: %s\n", pid, strerror(errno));

    if (pid != p)
        return;

    if (WIFEXITED(stat) && WEXITSTATUS(stat))
        die("child exited with status %d\n", WEXITSTATUS(stat));
    else if (WIFSIGNALED(stat))
        die("child terminated due to signal %d\n", WTERMSIG(stat));
    _exit(0);
}

void stty(char **args) {
    char cmd[_POSIX_ARG_MAX], **p, *q, *s;
    size_t n, siz;

    if (!((n = strlen(stty_args)) < sizeof(cmd)))
        die("incorrect stty parameters\n");
    memcpy(cmd, stty_args, n);
    q = cmd + n;
    siz = sizeof(cmd) - n;
    for (p = args; p && (s = *p); ++p) {
        if (!((n = strlen(s)) < siz))
            die("stty parameter length too long\n");
        *q++ = ' ';
        memcpy(q, s, n);
        q += n;
        siz -= n + 1;
    }
    *q = '\0';
    if (system(cmd) != 0)
        perror("Couldn't call stty");
}

int ttynew(char *line, char *cmd, char *out, char **args) {
    int m, s;
    ZigMiscPlan print_plan;

    if (out) {
        print_plan = st_startprinterplan();
        tapplymisc(&print_plan);
        iofd = (!strcmp(out, "-")) ? 1 : open(out, O_WRONLY | O_CREAT, 0666);
        if (iofd < 0) {
            fprintf(stderr, "Error opening %s:%s\n", out, strerror(errno));
        }
    }

    if (line) {
        if ((cmdfd = open(line, O_RDWR)) < 0)
            die("open line '%s' failed: %s\n", line, strerror(errno));
        dup2(cmdfd, 0);
        stty(args);
        return cmdfd;
    }

    /* seems to work fine on linux, openbsd and freebsd */
    if (openpty(&m, &s, NULL, NULL, NULL) < 0)
        die("openpty failed: %s\n", strerror(errno));

    switch (pid = fork()) {
    case -1:
        die("fork failed: %s\n", strerror(errno));
        break;
    case 0:
        close(iofd);
        setsid(); /* create a new process group */
        dup2(s, 0);
        dup2(s, 1);
        dup2(s, 2);
        if (ioctl(s, TIOCSCTTY, NULL) < 0)
            die("ioctl TIOCSCTTY failed: %s\n", strerror(errno));
        close(s);
        close(m);
#ifdef __OpenBSD__
        if (pledge("stdio getpw proc exec", NULL) == -1)
            die("pledge\n");
#endif
        execsh(cmd, args);
        break;
    default:
#ifdef __OpenBSD__
        if (pledge("stdio rpath tty proc", NULL) == -1)
            die("pledge\n");
#endif
        close(s);
        cmdfd = m;
        signal(SIGCHLD, sigchld);
        break;
    }
    return cmdfd;
}

size_t ttyread(void) {
    static char buf[BUFSIZ];
    static int buflen = 0;
    int ret, written;

    /* append read bytes to unprocessed bytes */
    ret = read(cmdfd, buf + buflen, LEN(buf) - buflen);

    switch (ret) {
    case 0:
        exit(0);
    case -1:
        die("couldn't read from shell: %s\n", strerror(errno));
    default:
        buflen += ret;
        written = twrite(buf, buflen, 0);
        buflen -= written;
        /* keep any incomplete UTF-8 byte sequence for the next call */
        if (buflen > 0)
            memmove(buf, buf + written, buflen);
        return ret;
    }
}

void ttywrite(const char *s, size_t n, int may_echo) {
    const char *next;
    Arg arg = (Arg){.i = term.scr};

    kscrolldown(&arg);

    if (may_echo && IS_SET(MODE_ECHO))
        twrite(s, n, 1);

    if (!IS_SET(MODE_CRLF)) {
        ttywriteraw(s, n);
        return;
    }

    /* This is similar to how the kernel handles ONLCR for ttys */
    while (n > 0) {
        if (*s == '\r') {
            next = s + 1;
            ttywriteraw("\r\n", 2);
        } else {
            next = s;
            while ((size_t)(next - s) < n && *next != '\r')
                next++;
            ttywriteraw(s, next - s);
        }
        n -= next - s;
        s = next;
    }
}

void ttywriteraw(const char *s, size_t n) {
    fd_set wfd, rfd;
    ssize_t r;
    size_t lim = 256;

    /*
     * Remember that we are using a pty, which might be a modem line.
     * Writing too much will clog the line. That's why we are doing this
     * dance.
     * FIXME: Migrate the world to Plan 9.
     */
    while (n > 0) {
        FD_ZERO(&wfd);
        FD_ZERO(&rfd);
        FD_SET(cmdfd, &wfd);
        FD_SET(cmdfd, &rfd);

        /* Check if we can write. */
        if (pselect(cmdfd + 1, &rfd, &wfd, NULL, NULL, NULL) < 0) {
            if (errno == EINTR)
                continue;
            die("select failed: %s\n", strerror(errno));
        }
        if (FD_ISSET(cmdfd, &wfd)) {
            /*
             * Only write the bytes written by ttywrite() or the
             * default of 256. This seems to be a reasonable value
             * for a serial line. Bigger values might clog the I/O.
             */
            if ((r = write(cmdfd, s, n < lim ? n : lim)) < 0)
                goto write_error;
            if (r < n) {
                /*
                 * We weren't able to write out everything.
                 * This means the buffer is getting full
                 * again. Empty it.
                 */
                if (n < lim)
                    lim = ttyread();
                n -= r;
                s += r;
            } else {
                /* All bytes have been written. */
                break;
            }
        }
        if (FD_ISSET(cmdfd, &rfd))
            lim = ttyread();
    }
    return;

write_error:
    die("write error on tty: %s\n", strerror(errno));
}

void ttyresize(int tw, int th) {
    struct winsize w;

    w.ws_row = term.row;
    w.ws_col = term.col;
    w.ws_xpixel = tw;
    w.ws_ypixel = th;
    if (ioctl(cmdfd, TIOCSWINSZ, &w) < 0)
        fprintf(stderr, "Couldn't set window size: %s\n", strerror(errno));
}

void ttyhangup() {
    /* Send SIGHUP to shell */
    kill(pid, SIGHUP);
}

int tattrset(int attr) { return st_tattrset((const ZigGlyph *const *)term.line, term.row, term.col, attr); }

void tsetdirt(int top, int bot) {
    ZigLineRange range;

    range = st_tsetdirtrange(top, bot, term.row);
    termapplydirtyrange(range);
}

static void termapplydirtyrange(ZigLineRange range) {
    int i;

    for (i = range.top; i <= range.bot; i++)
        term.dirty[i] = 1;
}

void tsetdirtattr(int attr) {
    int i;

    for (i = 0; i < term.row - 1; i++) {
        if (st_tlineattrset((const ZigGlyph *)term.line[i], term.col, attr))
            tsetdirt(i, i);
    }
}

void tfulldirt(void) { tsetdirt(0, term.row - 1); }

void tcursor(int mode) {
    static TCursor c[2];
    ZigTermCursorSnapshot snapshot;
    ZigTermCursorPlan plan;

    snapshot = (ZigTermCursorSnapshot){term.c.state, term.c.x, term.c.y, term.col, term.row, term.top, term.bot};
    plan = st_termcursorplan(ST_ZIG_TERM_CURSOR_STORE, snapshot, mode, IS_SET(MODE_ALTSCREEN));
    if (plan.action == ST_ZIG_CURSOR_STORE_SAVE) {
        c[plan.slot] = term.c;
    } else if (plan.action == ST_ZIG_CURSOR_STORE_LOAD) {
        term.c = c[plan.slot];
        tmoveto(c[plan.slot].x, c[plan.slot].y);
    }
}

void treset(void) {
    uint i;
    const ZigResetScreenStep *step;
    ZigResetExecPlan plan;

    plan = st_tresetexecplan(defaultfg, defaultbg, term.row);
    termapplyresetstate(&plan.state);
    st_tresettabs(term.tabs, term.col, tabspaces);

    if (plan.screen_step_count != 2)
        die("invalid reset screen step count: %d\n", plan.screen_step_count);
    for (i = 0; i < plan.screen_step_count; i++) {
        step = &plan.screen_steps[i];
        if (step->move_home)
            tmoveto(0, 0);
        if (step->save_cursor)
            tcursor(CURSOR_SAVE);
        if (step->clear)
            tclearregion(0, 0, term.col - 1, term.row - 1);
        if (step->swap_screen)
            tswapscreen();
    }
}

void termapplyresetstate(const ZigResetPlan *state) {
    termapplystateupdate((TermStateUpdate){
        .set_cursor = 1,
        .cursor = (TCursor){{.mode = state->cursor_attr_mode, .fg = state->cursor_fg, .bg = state->cursor_bg},
                            .x = state->cursor_x,
                            .y = state->cursor_y,
                            .state = state->cursor_state},
        .mode_mask = ~0,
        .mode_bits = state->mode,
        .set_charset = 1,
        .charset = state->charset,
        .set_all_trantbl = 1,
        .all_trantbl_charset = state->trantbl,
        .set_scroll_region = 1,
        .top = state->top,
        .bot = state->bot,
    });
}

void tnew(int col, int row) {
    term = (Term){.c = {.attr = {.fg = defaultfg, .bg = defaultbg}}};
    tresize(col, row);
    treset();
}

void tswapscreen(void) {
    Line *tmp = term.line;

    term.line = term.alt;
    term.alt = tmp;
    term.mode ^= MODE_ALTSCREEN;
    tfulldirt();
}

void kscrolldown(const Arg *a) {
    ZigKScrollPlan plan;

    plan = st_kscrolldownplan(a->i, term.row, term.scr);
    if (plan.run) {
        term.scr = plan.new_scr;
        if (plan.selscroll_delta)
            selscroll(0, plan.selscroll_delta);
        if (plan.full_dirty)
            tfulldirt();
    }
}

void kscrollup(const Arg *a) {
    ZigKScrollPlan plan;

    plan = st_kscrollupplan(a->i, term.row, term.scr, HISTSIZE);
    if (plan.run) {
        term.scr = plan.new_scr;
        if (plan.selscroll_delta)
            selscroll(0, plan.selscroll_delta);
        if (plan.full_dirty)
            tfulldirt();
    }
}

void tscrolldown(int orig, int n, int copyhist) {
    ZigScrollPlan plan;

    plan = st_tscrollplan(n, orig, term.bot, term.scr, HISTSIZE, 0, copyhist, term.histi);
    tapplyscrollplan(&plan, orig);
}

void tscrollup(int orig, int n, int copyhist) {
    ZigScrollPlan plan;

    plan = st_tscrollplan(n, orig, term.bot, term.scr, HISTSIZE, 1, copyhist, term.histi);
    tapplyscrollplan(&plan, orig);
}

void tapplyscrollplan(const ZigScrollPlan *plan, int orig) {
    int i, step_index;
    Line temp;
    ZigScrollStep step;

    for (step_index = 0; step_index < plan->step_count; step_index++) {
        step = plan->steps[step_index];
        switch (step.kind) {
        case ST_ZIG_SCROLL_STEP_HIST_SWAP:
            term.histi = step.a;
            temp = term.hist[term.histi];
            term.hist[term.histi] = term.line[step.b];
            term.line[step.b] = temp;
            break;
        case ST_ZIG_SCROLL_STEP_SCR_UPDATE:
            term.scr = step.a;
            break;
        case ST_ZIG_SCROLL_STEP_CLEAR_RECT:
            tclearregion(step.a, step.b, term.col + step.c, step.d);
            break;
        case ST_ZIG_SCROLL_STEP_DIRTY_RANGE:
            tsetdirt(step.a, step.b);
            break;
        case ST_ZIG_SCROLL_STEP_LINE_SWAP_LOOP:
            if (step.c > 0) {
                for (i = step.a; i <= step.b; i += step.c) {
                    temp = term.line[i];
                    term.line[i] = term.line[i + step.d];
                    term.line[i + step.d] = temp;
                }
            } else {
                for (i = step.a; i >= step.b; i += step.c) {
                    temp = term.line[i];
                    term.line[i] = term.line[i + step.d];
                    term.line[i + step.d] = temp;
                }
            }
            break;
        case ST_ZIG_SCROLL_STEP_SELECTION_SCROLL:
            selscroll(orig, step.a);
            break;
        default:
            die("invalid scroll step: kind=%d index=%d count=%d\n", step.kind, step_index, plan->step_count);
        }
    }
}

void selscroll(int orig, int n) {
    ZigSelectionStateResult result;

    result = st_selscrollupdate(selectionsnapshot(), orig, term.top, term.bot, n);
    selectionapplyscrollresult(result);
}

void tnewline(int first_col) {
    ZigTermCursorSnapshot snapshot;
    ZigTermCursorPlan plan;

    snapshot = (ZigTermCursorSnapshot){term.c.state, term.c.x, term.c.y, term.col, term.row, term.top, term.bot};
    plan = st_termcursorplan(ST_ZIG_TERM_CURSOR_NEWLINE, snapshot, first_col, 0);
    termapplycursorplan(&plan);
}

void termapplycursorplan(const ZigTermCursorPlan *plan) {
    if (plan->scroll) {
        if (plan->scroll_down)
            tscrolldown(plan->scroll_top, 1, 1);
        else
            tscrollup(plan->scroll_top, 1, 1);
    }
    term.c.state = plan->state;
    term.c.x = plan->x;
    term.c.y = plan->y;
}

void termapplystateupdate(TermStateUpdate update) {
    if (update.set_cursor)
        term.c = update.cursor;
    if (update.mode_mask)
        term.mode = (term.mode & ~update.mode_mask) | update.mode_bits;
    if (update.cursor_state_mask)
        term.c.state = (term.c.state & ~update.cursor_state_mask) | update.cursor_state_bits;
    if (update.set_charset)
        term.charset = update.charset;
    if (update.set_trantbl)
        term.trantbl[update.trantbl_slot] = update.trantbl_charset;
    if (update.set_all_trantbl)
        memset(term.trantbl, update.all_trantbl_charset, sizeof(term.trantbl));
    if (update.set_scroll_region) {
        term.top = update.top;
        term.bot = update.bot;
    }
    if (update.set_dimensions) {
        term.col = update.col;
        term.maxcol = update.maxcol;
        term.row = update.row;
    }
    if (update.clamp_cursor)
        tmoveto(term.c.x, term.c.y);
}

void csiparse(void) {
    ZigCsiParse parsed;

    parsed = st_csiparse((const unsigned char *)csiescseq.buf, csiescseq.len);
    csiescseq.priv = parsed.priv != 0;
    csiescseq.narg = parsed.narg;
    memcpy(csiescseq.arg, parsed.arg, sizeof(parsed.arg));
    csiescseq.mode[0] = parsed.mode[0];
    csiescseq.mode[1] = parsed.mode[1];
}

/* for absolute user moves, when decom is set */
void tmoveato(int x, int y) {
    ZigTermCursorSnapshot snapshot;
    ZigTermCursorPlan plan;

    snapshot = (ZigTermCursorSnapshot){term.c.state, term.c.x, term.c.y, term.col, term.row, term.top, term.bot};
    plan = st_termcursorplan(ST_ZIG_TERM_CURSOR_MOVE_TO_ABS, snapshot, x, y);
    termapplycursorplan(&plan);
}

void tmoveto(int x, int y) {
    ZigTermCursorSnapshot snapshot;
    ZigTermCursorPlan plan;

    snapshot = (ZigTermCursorSnapshot){term.c.state, term.c.x, term.c.y, term.col, term.row, term.top, term.bot};
    plan = st_termcursorplan(ST_ZIG_TERM_CURSOR_MOVE_TO, snapshot, x, y);
    termapplycursorplan(&plan);
}

void tsetchar(Rune u, Glyph *attr, int x, int y) {
    st_tsetchar(u, (const ZigGlyph *)attr, (ZigGlyph *)term.line[y], x, term.col, term.trantbl[term.charset]);
    tsetdirt(y, y);
    if (isboxdraw(term.line[y][x].u))
        term.line[y][x].mode |= ATTR_BOXDRAW;
}

void tclearregion(int x1, int y1, int x2, int y2) {
    int x, y;
    ZigClearRect rect;
    Glyph *gp;

    rect = st_tclearregionrect(x1, y1, x2, y2, term.maxcol, term.row);
    x1 = rect.x1;
    y1 = rect.y1;
    x2 = rect.x2;
    y2 = rect.y2;

    tsetdirt(y1, y2);
    for (y = y1; y <= y2; y++) {
        for (x = x1; x <= x2; x++) {
            if (selected(x, y))
                selclear();
            gp = &term.line[y][x];
            st_tclearglyph((ZigGlyph *)gp, 0, (const ZigGlyph *)&term.c.attr);
        }
    }
}

void tdeletechar(int n) {
    ZigEditMove move;
    Glyph *line;

    move = st_tdeletechar(n, term.c.x, term.col);
    line = term.line[term.c.y];

    memmove(&line[move.dst], &line[move.src], move.size * sizeof(Glyph));
    tclearregion(move.clear_x1, term.c.y, move.clear_x2, term.c.y);
}

void tinsertblank(int n) {
    ZigEditMove move;
    Glyph *line;

    move = st_tinsertblank(n, term.c.x, term.col);
    line = term.line[term.c.y];

    memmove(&line[move.dst], &line[move.src], move.size * sizeof(Glyph));
    tclearregion(move.clear_x1, term.c.y, move.clear_x2, term.c.y);
}

void tinsertblankline(int n) {
    if (term.top <= term.c.y && term.c.y <= term.bot)
        tscrolldown(term.c.y, n, 0);
}

void tdeleteline(int n) {
    if (term.top <= term.c.y && term.c.y <= term.bot)
        tscrollup(term.c.y, n, 0);
}

void tsetattr(int *attr, int l) {
    ZigAttrUpdate update;

    update = st_tsetattr(
        (ZigAttrState){
            .mode = term.c.attr.mode,
            .fg = term.c.attr.fg,
            .bg = term.c.attr.bg,
        },
        defaultfg, defaultbg, attr, l);

    term.c.attr.mode = update.state.mode;
    term.c.attr.fg = update.state.fg;
    term.c.attr.bg = update.state.bg;

    switch (update.color_error.kind) {
    case ST_ZIG_COLOR_BAD_COUNT:
        fprintf(stderr, "erresc(38): Incorrect number of parameters (%d)\n", update.color_error.input_npar);
        break;
    case ST_ZIG_COLOR_BAD_RGB:
        fprintf(stderr, "erresc: bad rgb color (%u,%u,%u)\n", update.color_error.r, update.color_error.g,
                update.color_error.b);
        break;
    case ST_ZIG_COLOR_BAD_INDEX:
        fprintf(stderr, "erresc: bad fgcolor %d\n", update.color_error.value);
        break;
    case ST_ZIG_COLOR_UNKNOWN:
        fprintf(stderr, "erresc(38): gfx attr %d unknown\n", update.color_error.value);
        break;
    }

    if (update.error_kind == ST_ZIG_ATTR_ERROR_UNKNOWN) {
        fprintf(stderr, "erresc(default): gfx attr %d unknown\n", update.error_value);
        csidump();
    }
}

void tsetscroll(int t, int b) {
    ZigScrollRegion region;

    region = st_tsetscroll(t, b, term.row);
    termapplystateupdate((TermStateUpdate){.set_scroll_region = 1, .top = region.top, .bot = region.bottom});
}

void tapplyerase(const ZigErasePlan *plan) {
    int i;

    for (i = 0; i < plan->count; ++i) {
        tclearregion(plan->rects[i].x1, plan->rects[i].y1, plan->rects[i].x2, plan->rects[i].y2);
    }
}

void tapplycursor(const ZigCursorPlan *plan) {
    switch (plan->kind) {
    case ST_ZIG_CURSOR_MOVE_TO:
        tmoveto(plan->x, plan->y);
        break;
    case ST_ZIG_CURSOR_MOVE_TO_ABS:
        tmoveato(plan->x, plan->y);
        break;
    }
}

void tapplyedit(const ZigEditPlan *plan) {
    switch (plan->kind) {
    case ST_ZIG_EDIT_INSERT_BLANK:
        tinsertblank(plan->count);
        break;
    case ST_ZIG_EDIT_SCROLL_UP:
        tscrollup(term.top, plan->count, 0);
        break;
    case ST_ZIG_EDIT_SCROLL_DOWN:
        tscrolldown(term.top, plan->count, 0);
        break;
    case ST_ZIG_EDIT_INSERT_BLANK_LINE:
        tinsertblankline(plan->count);
        break;
    case ST_ZIG_EDIT_DELETE_LINE:
        tdeleteline(plan->count);
        break;
    case ST_ZIG_EDIT_CLEAR_REGION:
        tclearregion(plan->rect.x1, plan->rect.y1, plan->rect.x2, plan->rect.y2);
        break;
    case ST_ZIG_EDIT_DELETE_CHAR:
        tdeletechar(plan->count);
        break;
    }
}

void tapplylight(const ZigLightPlan *plan, char *buf, int *len) {
    switch (plan->kind) {
    case ST_ZIG_LIGHT_CLEAR_TAB_CURRENT:
        break;
    case ST_ZIG_LIGHT_CLEAR_TAB_ALL:
        break;
    case ST_ZIG_LIGHT_PUT_TAB:
        tputtab(plan->value);
        break;
    case ST_ZIG_LIGHT_WRITE_VTIDENT:
        ttywrite(vtiden, strlen(vtiden), 0);
        break;
    case ST_ZIG_LIGHT_WRITE_CURSOR_POSITION:
        *len = snprintf(buf, 40, "\033[%i;%iR", plan->y, plan->x);
        ttywrite(buf, *len, 0);
        break;
    }
    if (plan->tab_clear_current)
        term.tabs[term.c.x] = 0;
    if (plan->tab_clear_all)
        memset(term.tabs, 0, term.col * sizeof(*term.tabs));
}

void tapplystate(const ZigStatePlan *plan) {
    switch (plan->kind) {
    case ST_ZIG_STATE_SET_SCROLL:
        tsetscroll(plan->top, plan->bottom);
        if (plan->cursor_home)
            tmoveato(0, 0);
        break;
    case ST_ZIG_STATE_SAVE_CURSOR:
        tcursor(CURSOR_SAVE);
        break;
    case ST_ZIG_STATE_LOAD_CURSOR:
        tcursor(CURSOR_LOAD);
        break;
    }
}

void tapplymisc(const ZigMiscPlan *plan) {
    int count;

    switch (plan->kind) {
    case ST_ZIG_MISC_MEDIA_DUMP:
        tdump();
        break;
    case ST_ZIG_MISC_MEDIA_DUMP_LINE:
        tdumpline(term.c.y);
        break;
    case ST_ZIG_MISC_MEDIA_DUMP_SEL:
        tdumpsel();
        break;
    case ST_ZIG_MISC_MEDIA_PRINT_OFF:
    case ST_ZIG_MISC_MEDIA_PRINT_ON:
        break;
    case ST_ZIG_MISC_REPEAT_LAST:
        if (!term.lastc)
            break;
        for (count = plan->value; count > 0; --count)
            tputc(term.lastc);
        break;
    }
    termapplystateupdate((TermStateUpdate){.mode_mask = plan->mode_mask, .mode_bits = plan->mode_bits});
}

void tsetmode(int priv, int set, int *args, int narg) {
    ZigModePlan plan;
    int *lim;

    for (lim = args + narg; args < lim; ++args) {
        plan = st_modeplan(priv, *args, set, IS_SET(MODE_ALTSCREEN));

        switch (plan.kind) {
        case ST_ZIG_MODE_IGNORE:
            break;
        case ST_ZIG_MODE_APPCURSOR:
            xsetmode(set, MODE_APPCURSOR);
            break;
        case ST_ZIG_MODE_REVERSE:
            xsetmode(set, MODE_REVERSE);
            break;
        case ST_ZIG_MODE_ORIGIN:
            termapplystateupdate((TermStateUpdate){.cursor_state_mask = plan.cursor_state_mask,
                                                   .cursor_state_bits = plan.cursor_state_bits});
            if (plan.move_origin_home)
                tmoveato(0, 0);
            break;
        case ST_ZIG_MODE_WRAP:
            break;
        case ST_ZIG_MODE_CURSOR_VISIBILITY:
            if (plan.xsetmode_action == ST_ZIG_XSETMODE_HIDE)
                xsetmode(plan.xsetmode_set, MODE_HIDE);
            break;
        case ST_ZIG_MODE_MOUSE_X10:
        case ST_ZIG_MODE_MOUSE_BTN:
        case ST_ZIG_MODE_MOUSE_MOTION:
        case ST_ZIG_MODE_MOUSE_MANY:
            if (plan.pointer_motion >= 0)
                xsetpointermotion(plan.pointer_motion);
            if (plan.clear_mouse_mode)
                xsetmode(0, MODE_MOUSE);
            switch (plan.mouse_mode) {
            case ST_ZIG_MOUSE_X10:
                xsetmode(set, MODE_MOUSEX10);
                break;
            case ST_ZIG_MOUSE_BUTTON:
                xsetmode(set, MODE_MOUSEBTN);
                break;
            case ST_ZIG_MOUSE_MOTION:
                xsetmode(set, MODE_MOUSEMOTION);
                break;
            case ST_ZIG_MOUSE_MANY:
                xsetmode(set, MODE_MOUSEMANY);
                break;
            }
            break;
        case ST_ZIG_MODE_FOCUS:
            xsetmode(set, MODE_FOCUS);
            break;
        case ST_ZIG_MODE_MOUSE_SGR:
            if (plan.mouse_mode == ST_ZIG_MOUSE_SGR)
                xsetmode(set, MODE_MOUSESGR);
            break;
        case ST_ZIG_MODE_8BIT:
            xsetmode(set, MODE_8BIT);
            break;
        case ST_ZIG_MODE_ALT1049:
            if (!allowaltscreen)
                break;
            if (plan.cursor_before >= 0)
                tcursor(plan.cursor_before);
            if (plan.clear_before_swap)
                tclearregion(0, 0, term.col - 1, term.row - 1);
            if (plan.swap_screen)
                tswapscreen();
            if (plan.cursor_after >= 0)
                tcursor(plan.cursor_after);
            break;
        case ST_ZIG_MODE_ALT47:
            if (!allowaltscreen)
                break;
            if (plan.clear_before_swap)
                tclearregion(0, 0, term.col - 1, term.row - 1);
            if (plan.swap_screen)
                tswapscreen();
            break;
        case ST_ZIG_MODE_CURSOR1048:
            if (plan.cursor_after >= 0)
                tcursor(plan.cursor_after);
            break;
        case ST_ZIG_MODE_BRACKETED_PASTE:
            xsetmode(set, MODE_BRCKTPASTE);
            break;
        case ST_ZIG_MODE_KBDLOCK:
            if (plan.xsetmode_action == ST_ZIG_XSETMODE_KBDLOCK)
                xsetmode(plan.xsetmode_set, MODE_KBDLOCK);
            break;
        case ST_ZIG_MODE_INSERT:
        case ST_ZIG_MODE_ECHO:
        case ST_ZIG_MODE_CRLF:
            break;
        case ST_ZIG_MODE_PRIVATE_UNKNOWN:
            fprintf(stderr, "erresc: unknown private set/reset mode %d\n", *args);
            break;
        case ST_ZIG_MODE_REGULAR_UNKNOWN:
            fprintf(stderr, "erresc: unknown set/reset mode %d\n", *args);
            break;
        }
        termapplystateupdate((TermStateUpdate){.mode_mask = plan.mode_mask, .mode_bits = plan.mode_bits});
    }
}

void csihandle(void) {
    char buf[40];
    int len;
    ZigCsiExecPlan plan;

    plan = st_csiexecplan(csiescseq.mode[0], csiescseq.mode[1], csiescseq.priv, csiescseq.arg, csiescseq.narg, term.c.x,
                          term.c.y, term.col, term.row);

    switch (plan.kind) {
    case ST_ZIG_CSI_EXEC_UNKNOWN:
        fprintf(stderr, "erresc: unknown csi ");
        csidump();
        /* die(""); */
        break;
    case ST_ZIG_CSI_EXEC_EDIT:
        tapplyedit(&plan.edit);
        break;
    case ST_ZIG_CSI_EXEC_CURSOR:
        tapplycursor(&plan.cursor);
        break;
    case ST_ZIG_CSI_EXEC_MISC:
        if (plan.misc.kind == ST_ZIG_MISC_SET_CURSOR_STYLE && xsetcursor(plan.misc.value)) {
            fprintf(stderr, "erresc: unknown csi ");
            csidump();
            break;
        }
        tapplymisc(&plan.misc);
        break;
    case ST_ZIG_CSI_EXEC_LIGHT:
        tapplylight(&plan.light, buf, &len);
        break;
    case ST_ZIG_CSI_EXEC_ERASE:
        tapplyerase(&plan.erase);
        break;
    case ST_ZIG_CSI_EXEC_MODE:
        tsetmode(csiescseq.priv, plan.mode_set, csiescseq.arg, csiescseq.narg);
        break;
    case ST_ZIG_CSI_EXEC_ATTR:
        tsetattr(csiescseq.arg, csiescseq.narg);
        break;
    case ST_ZIG_CSI_EXEC_STATE:
        tapplystate(&plan.state);
        break;
    }
}

void csidump(void) {
    size_t i;
    uint c;

    fprintf(stderr, "ESC[");
    for (i = 0; i < csiescseq.len; i++) {
        c = csiescseq.buf[i] & 0xff;
        if (isprint(c)) {
            putc(c, stderr);
        } else if (c == '\n') {
            fprintf(stderr, "(\\n)");
        } else if (c == '\r') {
            fprintf(stderr, "(\\r)");
        } else if (c == 0x1b) {
            fprintf(stderr, "(\\e)");
        } else {
            fprintf(stderr, "(%02x)", c);
        }
    }
    putc('\n', stderr);
}

void csireset(void) { memset(&csiescseq, 0, sizeof(csiescseq)); }

char *strarg(const ZigStrHandlePlan *plan, int index, int narg, const char *label) {
    if (index < 0 || index >= narg) {
        if (plan)
            die("invalid str arg index label=%s index=%d narg=%d kind=%d\n", label, index, narg, plan->kind);
        die("invalid str arg index label=%s index=%d narg=%d plan=NULL\n", label, index, narg);
    }
    return strescseq.args[index];
}

char *strargpar(int index, int narg) {
    if (index < 0 || index >= narg)
        die("invalid str par arg index=%d narg=%d\n", index, narg);
    return strescseq.args[index];
}

void strapplyplan(const ZigStrHandlePlan *plan, int narg) {
    ZigStrApplyEffectList exec;
    ZigStrApplyEffect effect;
    PlatformEffectList platform;
    int i;

    /* strarg() 将旧版空参数 UB 收敛为带上下文的显式错误。 */
    exec = st_strapplyplan(plan->kind, plan->clipboard_run, plan->arg1_present, plan->payload_arg, plan->color_arg);
    platform.count = exec.count;
    for (i = 0; i < exec.count; i++) {
        effect = exec.effects[i];
        platform.effects[i] = (PlatformEffect){.kind = effect.kind, .arg = effect.arg, .index_arg = effect.index_arg};
    }
    platformapplyeffects(&platform, plan, narg);
}

void platformapplyeffects(const PlatformEffectList *platform, const ZigStrHandlePlan *plan, int narg) {
    PlatformEffect effect;
    char *p = NULL, *dec;
    int color_failed, i, j;

    dec = NULL;
    color_failed = 0;
    for (i = 0; i < platform->count; i++) {
        effect = platform->effects[i];
        switch (effect.kind) {
        case 0:
            break;
        case 1:
            xsettitle(strarg(plan, effect.arg, narg, "title"));
            break;
        case 2:
            xseticontitle(strarg(plan, effect.arg, narg, "icon-title"));
            break;
        case 3:
            dec = base64dec(strarg(plan, effect.arg, narg, "clipboard"));
            if (!dec)
                fprintf(stderr, "erresc: invalid base64\n");
            break;
        case 4:
            if (dec)
                xsetsel(dec);
            break;
        case 5:
            if (dec)
                xclipcopy();
            break;
        case 6:
            p = strarg(plan, effect.arg, narg, "color-value");
            j = effect.index_arg >= 0 ? atoi(strarg(plan, effect.index_arg, narg, "color-index")) : -1;
            if (xsetcolorname(j, p)) {
                color_failed = 1;
                fprintf(stderr, "erresc: invalid color j=%d, p=%s\n", j, p ? p : "(null)");
            }
            break;
        case 7:
            j = atoi(strarg(plan, effect.index_arg, narg, "color-index"));
            /* OSC 104 带参数时重置指定颜色槽；NULL 要求 xsetcolorname 恢复默认值。 */
            if (xsetcolorname(j, p)) {
                color_failed = 1;
                fprintf(stderr, "erresc: invalid color j=%d, p=%s\n", j, p ? p : "(null)");
            }
            break;
        case 8:
            if (!color_failed)
                redraw();
            break;
        case 9:
            fprintf(stderr, "erresc: unknown str ");
            strdump();
            return;
        default:
            fprintf(stderr, "erresc: invalid str effect kind=%d\n", effect.kind);
            strdump();
            return;
        }
    }

    return;
}

void strhandle(void) {
    ZigStrHandleParPlan par_plan;
    ZigStrHandlePlan plan;
    int narg, par;

    term.esc &= ~(ESC_STR_END | ESC_STR);
    strparse();
    narg = strescseq.narg;
    par_plan = st_strhandleparplan(narg);
    par = par_plan.use_arg ? atoi(strargpar(par_plan.arg, narg)) : par_plan.default_value;
    plan = st_strhandleplan(strescseq.type, narg, par, allowwindowops);
    strapplyplan(&plan, narg);
}

void strparse(void) {
    ZigStrParse parsed;
    int i;

    strescseq.buf[strescseq.len] = '\0';
    strescseq.narg = 0;

    if (*strescseq.buf == '\0')
        return;

    parsed = st_strparse((const unsigned char *)strescseq.buf, strescseq.len);
    strescseq.narg = parsed.narg;
    for (i = 0; i < strescseq.narg; ++i) {
        strescseq.args[i] = &strescseq.buf[parsed.starts[i]];
        if (parsed.nul_terms[i])
            strescseq.buf[parsed.ends[i]] = '\0';
    }
}

void externalpipe(const Arg *arg) {
    int to[2];
    char buf[UTF_SIZ];
    void (*oldsigpipe)(int);
    Glyph *bp, *end;
    int lastpos, n, newline;
    ZigExternalPipePlan line_plan;

    if (pipe(to) == -1)
        return;

    switch (fork()) {
    case -1:
        close(to[0]);
        close(to[1]);
        return;
    case 0:
        dup2(to[0], STDIN_FILENO);
        close(to[0]);
        close(to[1]);
        execvp(((char **)arg->v)[0], (char **)arg->v);
        fprintf(stderr, "st: execvp %s\n", ((char **)arg->v)[0]);
        perror("failed");
        exit(0);
    }

    close(to[0]);
    /* ignore sigpipe for now, in case child exists early */
    oldsigpipe = signal(SIGPIPE, SIG_IGN);
    newline = 0;
    for (n = 0; n < HISTSIZE + 3; n++) {
        bp = tlinehist(n);
        line_plan = st_externalpipeplan((const ZigGlyph *)bp, term.col);
        if (line_plan.kind == ST_ZIG_EXTERNALPIPE_BREAK)
            break;
        if (line_plan.kind == ST_ZIG_EXTERNALPIPE_SKIP)
            continue;
        lastpos = line_plan.lastpos;
        end = &bp[lastpos + 1];
        for (; bp < end; ++bp)
            if (xwrite(to[1], buf, utf8encode(bp->u, buf)) < 0)
                break;
        if ((newline = line_plan.newline))
            continue;
        if (xwrite(to[1], "\n", 1) < 0)
            break;
        newline = 0;
    }
    if (newline)
        (void)xwrite(to[1], "\n", 1);
    close(to[1]);
    /* restore */
    signal(SIGPIPE, oldsigpipe);
}

void strdump(void) {
    size_t i;
    uint c;

    fprintf(stderr, "ESC%c", strescseq.type);
    for (i = 0; i < strescseq.len; i++) {
        c = strescseq.buf[i] & 0xff;
        if (c == '\0') {
            putc('\n', stderr);
            return;
        } else if (isprint(c)) {
            putc(c, stderr);
        } else if (c == '\n') {
            fprintf(stderr, "(\\n)");
        } else if (c == '\r') {
            fprintf(stderr, "(\\r)");
        } else if (c == 0x1b) {
            fprintf(stderr, "(\\e)");
        } else {
            fprintf(stderr, "(%02x)", c);
        }
    }
    fprintf(stderr, "ESC\\\n");
}

void strreset(void) {
    ZigStrResetPlan plan = st_strresetplan();

    strescseq = (STREscape){
        .buf = xrealloc(strescseq.buf, plan.size),
        .siz = plan.size,
    };
}

void sendbreak(const Arg *arg) {
    if (tcsendbreak(cmdfd, 0))
        perror("Error sending break");
}

void tprinter(char *s, size_t len) {
    if (iofd != -1 && xwrite(iofd, s, len) < 0) {
        perror("Error writing to output file");
        close(iofd);
        iofd = -1;
    }
}

void toggleprinter(const Arg *arg) {
    ZigMiscPlan plan;

    plan = st_toggleprinterplan(term.mode);
    termapplystateupdate((TermStateUpdate){.mode_mask = plan.mode_mask, .mode_bits = plan.mode_bits});
}

void printscreen(const Arg *arg) { tdump(); }

void printsel(const Arg *arg) { tdumpsel(); }

void tdumpsel(void) {
    char *ptr;

    if ((ptr = getsel())) {
        tprinter(ptr, strlen(ptr));
        free(ptr);
    }
}

void tdumpline(int n) {
    char buf[UTF_SIZ];
    Glyph *bp, *end;
    ZigDumpLinePlan plan;

    bp = &term.line[n][0];
    plan = st_tdumplineplan(tlinelen(n), term.col);
    if (plan.write) {
        end = &bp[plan.last];
        for (; bp <= end; ++bp)
            tprinter(buf, utf8encode(bp->u, buf));
    }
    tprinter("\n", 1);
}

void tdump(void) {
    int i;

    for (i = 0; i < term.row; ++i)
        tdumpline(i);
}

void tputtab(int n) { term.c.x = st_tputtab(term.c.x, term.col, n, term.tabs); }

void tdefutf8(char ascii) {
    termapplystateupdate((TermStateUpdate){.mode_mask = ~0, .mode_bits = st_tdefutf8plan(ascii, term.mode)});
}

void tdeftran(char ascii) {
    int charset = st_tdeftranplan(ascii);

    if (charset < 0) {
        fprintf(stderr, "esc unhandled charset: ESC ( %c\n", ascii);
    } else {
        termapplystateupdate(
            (TermStateUpdate){.set_trantbl = 1, .trantbl_slot = term.icharset, .trantbl_charset = charset});
    }
}

void tdectest(char c) {
    int x, y;

    if (c == '8') { /* DEC screen alignment test. */
        for (x = 0; x < term.col; ++x) {
            for (y = 0; y < term.row; ++y)
                tsetchar('E', &term.c.attr, x, y);
        }
    }
}

void tstrsequence(uchar c) {
    ZigStrSequence seq;

    seq = st_tstrsequence(c, term.esc);
    strreset();
    strescseq.type = seq.seq_type;
    term.esc = seq.esc;
}

void applyinputscalarwriteback(const ZigInputScalarStateUpdate *update) {
    term.esc = update->esc;
    if (update->charset_set)
        termapplystateupdate((TermStateUpdate){.set_charset = 1, .charset = update->charset});
    if (update->icharset_set)
        term.icharset = update->icharset;
    if (update->tab_set)
        term.tabs[update->tab_x] = 1;
}

void tcontrolcode(uchar ascii) {
    ZigInputControlPlan plan = st_inputcontrolplan(ascii, term.esc, term.charset, term.c.x);

    applyinputscalarwriteback(&plan.state);

    switch (plan.action) {
    case ST_ZIG_CTL_ACTION_TAB:
        tputtab(1);
        return;
    case ST_ZIG_CTL_ACTION_BACKSPACE:
        tmoveto(term.c.x - 1, term.c.y);
        return;
    case ST_ZIG_CTL_ACTION_CARRIAGE_RETURN:
        tmoveto(0, term.c.y);
        return;
    case ST_ZIG_CTL_ACTION_LINEFEED:
        tnewline(IS_SET(MODE_CRLF));
        return;
    case ST_ZIG_CTL_ACTION_BELL:
        if (term.esc & ESC_STR_END) {
            strhandle();
        } else {
            xbell();
        }
        break;
    case ST_ZIG_CTL_ACTION_ESCAPE:
        csireset();
        return;
    case ST_ZIG_CTL_ACTION_SUBSTITUTE:
        tsetchar('?', &term.c.attr, term.c.x, term.c.y);
        /* FALLTHROUGH */
    case ST_ZIG_CTL_ACTION_CANCEL:
        csireset();
        break;
    case ST_ZIG_CTL_ACTION_NEXT_LINE:
        tnewline(1);
        break;
    case ST_ZIG_CTL_ACTION_DECID:
        ttywrite(vtiden, strlen(vtiden), 0);
        break;
    case ST_ZIG_CTL_ACTION_START_STR:
        tstrsequence(ascii);
        return;
    }
    /* only CAN, SUB, \a and C1 chars interrupt a sequence */
    term.esc = plan.finish_esc;
}

/*
 * returns 1 when the sequence is finished and it hasn't to read
 * more characters for this sequence, otherwise 0
 */
int eschandle(uchar ascii) {
    ZigInputEscPlan exec = st_inputescplan(ascii, term.esc, term.charset, term.icharset, term.c.x);
    ZigTermCursorSnapshot cursor_snapshot;
    ZigTermCursorPlan cursor_plan;

    applyinputscalarwriteback(&exec.state);

    switch (exec.action) {
    case ST_ZIG_ESC_ACTION_START_STR:
        tstrsequence(ascii);
        break;
    case ST_ZIG_ESC_ACTION_IND:
        tnewline(0);
        break;
    case ST_ZIG_ESC_ACTION_NEL:
        tnewline(1);
        break;
    case ST_ZIG_ESC_ACTION_RI:
        cursor_snapshot =
            (ZigTermCursorSnapshot){term.c.state, term.c.x, term.c.y, term.col, term.row, term.top, term.bot};
        cursor_plan = st_termcursorplan(ST_ZIG_TERM_CURSOR_REVERSE_INDEX, cursor_snapshot, 0, 0);
        termapplycursorplan(&cursor_plan);
        break;
    case ST_ZIG_ESC_ACTION_DECID:
        ttywrite(vtiden, strlen(vtiden), 0);
        break;
    case ST_ZIG_ESC_ACTION_RIS:
        treset();
        resettitle();
        xloadcols();
        break;
    case ST_ZIG_ESC_ACTION_KEYPAD_APP:
        xsetmode(1, MODE_APPKEYPAD);
        break;
    case ST_ZIG_ESC_ACTION_KEYPAD_NORMAL:
        xsetmode(0, MODE_APPKEYPAD);
        break;
    case ST_ZIG_ESC_ACTION_CURSOR_SAVE:
        tcursor(CURSOR_SAVE);
        break;
    case ST_ZIG_ESC_ACTION_CURSOR_LOAD:
        tcursor(CURSOR_LOAD);
        break;
    case ST_ZIG_ESC_ACTION_ST:
        if (term.esc & ESC_STR_END)
            strhandle();
        break;
    case ST_ZIG_ESC_ACTION_UNKNOWN:
        fprintf(stderr, "erresc: unknown sequence ESC 0x%02X '%c'\n", (uchar)ascii, isprint(ascii) ? ascii : '.');
        break;
    }
    return exec.ret;
}

void tputc(Rune u) {
    char c[UTF_SIZ];
    ZigPutcDecode decoded;
    ZigPutcStepPlan putc_step;
    ZigInputRoutingPlan route;
    ZigStrCollectApplyPlan collect_plan;
    ZigStrCollectExec collect_exec;
    ZigInputEscFlowPlan escflow;
    int control;
    int esc_action_done, esc_action_index;
    int width, len;
    Glyph *gp;

    decoded = st_putcdecode(u, IS_SET(MODE_UTF8));
    control = decoded.control;
    width = decoded.width;
    len = decoded.len;
    memcpy(c, decoded.bytes, sizeof(decoded.bytes));
    route = st_inputroutingplan(term.esc, control);

    if (IS_SET(MODE_PRINT))
        tprinter(c, len);

    /*
     * STR sequence must be checked before anything else
     * because it uses all following characters until it
     * receives a ESC, a SUB, a ST or any other C1 control
     * character.
     */
    if (route.is_str) {
        collect_plan = st_tcollectstrapply(u, term.esc, (unsigned char *)strescseq.buf, strescseq.len,
                                           (const unsigned char *)c, len, strescseq.siz);
        collect_exec = collect_plan.first;
        if (collect_exec.kind == ST_ZIG_STR_COLLECT_FINISH) {
            term.esc = collect_exec.new_esc;
            goto check_control_code;
        }

        if (collect_exec.kind == ST_ZIG_STR_COLLECT_ABORT)
            return;

        if (collect_exec.kind == ST_ZIG_STR_COLLECT_GROW) {
            /*
             * Here is a bug in terminals. If the user never sends
             * some code to stop the str or esc command, then st
             * will stop responding. But this is better than
             * silently failing with unknown characters. At least
             * then users will report back.
             *
             * In the case users ever get fixed, here is the code:
             */
            /*
             * term.esc = 0;
             * strhandle();
             */
            strescseq.siz = collect_exec.new_size;
            strescseq.buf = xrealloc(strescseq.buf, strescseq.siz);
            if (collect_plan.retry) {
                collect_exec = st_tcollectstr(u, term.esc, (unsigned char *)strescseq.buf, strescseq.len,
                                              (const unsigned char *)c, len, strescseq.siz);
                if (collect_exec.kind == ST_ZIG_STR_COLLECT_GROW)
                    die("str collect retry still needs growth: len=%zu chunk=%zu size=%zu\n", strescseq.len,
                        (size_t)len, strescseq.siz);
            }
        }

        strescseq.len = collect_exec.new_len;
        return;
    }

check_control_code:
    /*
     * Actions of control codes must be performed as soon they arrive
     * because they can be embedded inside a control sequence, and
     * they must not cause conflicts with sequences.
     */
    if (route.is_control) {
        tcontrolcode(u);
        /*
         * control codes are not shown ever
         */
        if (term.esc == 0)
            term.lastc = 0;
        return;
    } else if (route.is_esc) {
        escflow = st_inputescflowplan(term.esc, u, csiescseq.len, sizeof(csiescseq.buf));
        esc_action_done = escflow.kind == ST_ZIG_ESC_FLOW_CSI ? escflow.handle_csi : 1;
        for (esc_action_index = 0; esc_action_index < escflow.action_count; esc_action_index++) {
            switch (escflow.actions[esc_action_index]) {
            case ST_ZIG_ESC_FLOW_ACTION_WRITE_CSI_BYTE:
                if (escflow.csi_write)
                    csiescseq.buf[csiescseq.len] = escflow.csi_byte;
                csiescseq.len = escflow.new_csi_len;
                break;
            case ST_ZIG_ESC_FLOW_ACTION_PARSE_CSI:
                csiparse();
                break;
            case ST_ZIG_ESC_FLOW_ACTION_HANDLE_CSI:
                csihandle();
                esc_action_done = 1;
                break;
            case ST_ZIG_ESC_FLOW_ACTION_DEFINE_UTF8:
                tdefutf8(u);
                break;
            case ST_ZIG_ESC_FLOW_ACTION_DEFINE_CHARSET:
                tdeftran(u);
                break;
            case ST_ZIG_ESC_FLOW_ACTION_DEC_TEST:
                tdectest(u);
                break;
            case ST_ZIG_ESC_FLOW_ACTION_ESC_HANDLE:
                esc_action_done = eschandle(u);
                break;
            default:
                die("invalid esc flow action: action=%d kind=%d rune=%u\n", escflow.actions[esc_action_index], escflow.kind, u);
            }
        }
        if ((escflow.kind == ST_ZIG_ESC_FLOW_CSI || escflow.kind == ST_ZIG_ESC_FLOW_ESC) && !esc_action_done)
            return;
        term.esc = escflow.finish_esc;
        /*
         * All characters which form part of a sequence are not
         * printed
         */
        return;
    }
    putc_step = st_tputcstepplan(selected(term.c.x, term.c.y), IS_SET(MODE_WRAP), term.c.state, term.c.x, width, term.col);
    if (putc_step.clear_selection)
        selclear();

    gp = &term.line[term.c.y][term.c.x];
    if (putc_step.wrapnext_newline) {
        gp->mode |= ATTR_WRAP;
        tnewline(1);
        gp = &term.line[term.c.y][term.c.x];
    }

    if (putc_step.overflow_newline) {
        tnewline(1);
        gp = &term.line[term.c.y][term.c.x];
    }

    if (putc_step.write_glyph)
        st_tputcwrite(u, width, (const ZigGlyph *)&term.c.attr, (ZigGlyph *)term.line[term.c.y], term.c.x, term.col,
                      term.trantbl[term.charset], IS_SET(MODE_INSERT));
    if (putc_step.mark_dirty)
        tsetdirt(term.c.y, term.c.y);
    term.lastc = u;
    if (putc_step.advance == ST_ZIG_PUTC_ADVANCE_MOVE) {
        tmoveto(putc_step.next_x, term.c.y);
    } else {
        termapplystateupdate((TermStateUpdate){.cursor_state_mask = putc_step.cursor_state_mask,
                                               .cursor_state_bits = putc_step.cursor_state_bits});
    }
}

int twrite(const char *buf, int buflen, int show_ctrl) {
    int charsize;
    Rune u;
    int n;
    ZigWriteControlPlan control_plan;

    for (n = 0; n < buflen; n += charsize) {
        if (IS_SET(MODE_UTF8)) {
            /* process a complete utf8 char */
            charsize = utf8decode(buf + n, &u, buflen - n);
            if (charsize == 0)
                break;
        } else {
            u = buf[n] & 0xFF;
            charsize = 1;
        }
        control_plan = st_twritecontrol(u, show_ctrl);
        u = control_plan.rune;
        if (control_plan.caret)
            tputc('^');
        if (control_plan.bracket)
            tputc('[');
        tputc(u);
    }
    return n;
}

void tresize(int col, int row) {
    int i, j, step_index;
    TCursor cursor;
    ZigResizeExecPlan exec_plan;
    ZigResizePlan base;

    exec_plan = st_tresizeexecplan(term.tabs, col, row, term.col, term.row, term.maxcol, term.c.y, tabspaces);
    base = exec_plan.base;
    term.maxcol = base.base_maxcol;
    col = base.alloc_col;

    if (base.invalid) {
        fprintf(stderr, "tresize: error resizing to %dx%d\n", col, row);
        return;
    }

    for (step_index = 0; step_index < exec_plan.step_count; step_index++) {
        switch (exec_plan.steps[step_index]) {
        case ST_ZIG_RESIZE_STEP_FREE_SLIDE_ROWS:
            for (i = 0; i < base.slide_count; i++) {
                free(term.line[i]);
                free(term.alt[i]);
            }
            break;
        case ST_ZIG_RESIZE_STEP_MEMMOVE_SLIDE_ROWS:
            if (base.slide_count > 0) {
                memmove(term.line, term.line + base.slide_count, row * sizeof(Line));
                memmove(term.alt, term.alt + base.slide_count, row * sizeof(Line));
            }
            break;
        case ST_ZIG_RESIZE_STEP_FREE_TAIL_ROWS:
            for (i = base.tail_start; i < term.row; i++) {
                free(term.line[i]);
                free(term.alt[i]);
            }
            break;
        case ST_ZIG_RESIZE_STEP_REALLOC_ARRAYS:
            term.line = xrealloc(term.line, row * sizeof(Line));
            term.alt = xrealloc(term.alt, row * sizeof(Line));
            term.dirty = xrealloc(term.dirty, row * sizeof(*term.dirty));
            term.tabs = xrealloc(term.tabs, col * sizeof(*term.tabs));
            break;
        case ST_ZIG_RESIZE_STEP_FILL_HISTORY:
            for (i = 0; i < HISTSIZE; i++) {
                term.hist[i] = xrealloc(term.hist[i], col * sizeof(Glyph));
                for (j = exec_plan.hist_fill.start; exec_plan.hist_fill.run && j < exec_plan.hist_fill.end; j++) {
                    term.hist[i][j] = term.c.attr;
                    term.hist[i][j].u = ' ';
                }
            }
            break;
        case ST_ZIG_RESIZE_STEP_REALLOC_ROWS:
            for (i = exec_plan.rows.resize_start; i < exec_plan.rows.resize_end; i++) {
                term.line[i] = xrealloc(term.line[i], col * sizeof(Glyph));
                term.alt[i] = xrealloc(term.alt[i], col * sizeof(Glyph));
            }
            break;
        case ST_ZIG_RESIZE_STEP_ALLOC_ROWS:
            for (i = exec_plan.rows.alloc_start; i < exec_plan.rows.alloc_end; i++) {
                term.line[i] = xmalloc(col * sizeof(Glyph));
                term.alt[i] = xmalloc(col * sizeof(Glyph));
            }
            break;
        case ST_ZIG_RESIZE_STEP_TABS:
            if (exec_plan.tabs.grow) {
                memset(term.tabs + exec_plan.tabs.clear_start, 0, sizeof(*term.tabs) * exec_plan.tabs.clear_count);
                for (i = exec_plan.tabs.tab_start; i < col; i += tabspaces)
                    term.tabs[i] = 1;
            }
            break;
        case ST_ZIG_RESIZE_STEP_UPDATE_DIMENSIONS:
            termapplystateupdate((TermStateUpdate){
                .set_dimensions = 1,
                .col = base.requested_col,
                .maxcol = base.alloc_col,
                .row = row,
                .set_scroll_region = 1,
                .top = 0,
                .bot = row - 1,
                .clamp_cursor = 1,
            });
            break;
        case ST_ZIG_RESIZE_STEP_CLEAR_REGIONS:
            cursor = term.c;
            for (i = 0; i < 2; i++) {
                for (j = 0; j < exec_plan.clear.count; j++)
                    tclearregion(exec_plan.clear.rects[j].x1, exec_plan.clear.rects[j].y1, exec_plan.clear.rects[j].x2,
                                 exec_plan.clear.rects[j].y2);
                tswapscreen();
                tcursor(CURSOR_LOAD);
            }
            term.c = cursor;
            break;
        default:
            die("invalid resize step: step=%d index=%d count=%d\n", exec_plan.steps[step_index], step_index, exec_plan.step_count);
        }
    }
}

void resettitle(void) { xsettitle(NULL); }

void drawregion(int x1, int y1, int x2, int y2) {
    int y = y1;
    ZigTermFrameSnapshot snapshot;
    ZigDrawExecPlan region;

    snapshot = (ZigTermFrameSnapshot){0, 1, 0, 0, 0, 0, term.col, term.row};

    for (;;) {
        region = st_drawexecplan(snapshot, (const ZigGlyph *const *)term.line, term.dirty, y, y2);
        if (!region.region_draw)
            break;
        y = region.region_y;
        if (region.region_clear_dirty)
            term.dirty[y] = 0;
        xdrawline(TLINE(y), x1, y, x2);
        y = region.region_next_y;
    }
}

void draw(void) {
    ZigTermFrameSnapshot snapshot;
    ZigDrawExecPlan frame;

    if (!xstartdraw())
        return;
    snapshot =
        (ZigTermFrameSnapshot){search.active, term.scr, term.c.x, term.c.y, term.ocx, term.ocy, term.col, term.row};
    frame = st_drawexecplan(snapshot, (const ZigGlyph *const *)term.line, term.dirty, 0, term.row);
    if (frame.search_scan)
        searchscan();

    term.ocx = frame.ocx;
    term.ocy = frame.ocy;

    if (frame.region_draw)
        drawregion(0, frame.region_y, term.col, term.row);
    if (frame.cursor_active)
        xdrawcursor(frame.cx, term.c.y, term.line[term.c.y][frame.cx], term.ocx, term.ocy,
                    term.line[term.ocy][term.ocx], term.line[term.ocy], term.col);
    term.ocx = frame.new_ocx;
    term.ocy = frame.new_ocy;
    xfinishdraw();
    if (frame.imspot_active)
        xximspot(term.ocx, term.ocy);
}

void redraw(void) {
    tfulldirt();
    draw();
}
