/* See LICENSE for license details. */
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
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

#if   defined(__linux)
 #include <pty.h>
#elif defined(__OpenBSD__) || defined(__NetBSD__) || defined(__APPLE__)
 #include <util.h>
#elif defined(__FreeBSD__) || defined(__DragonFly__)
 #include <libutil.h>
#endif

/* Arbitrary sizes */
#define UTF_INVALID   0xFFFD
#define UTF_SIZ       4
#define ESC_BUF_SIZ   (128*UTF_SIZ)
#define ESC_ARG_SIZ   16
#define STR_BUF_SIZ   ESC_BUF_SIZ
#define STR_ARG_SIZ   ESC_ARG_SIZ
#define HISTSIZE      2000

/* macros */
#define IS_SET(flag)		((term.mode & (flag)) != 0)
#define ISCONTROLC0(c)		(BETWEEN(c, 0, 0x1f) || (c) == 0x7f)
#define ISCONTROLC1(c)		(BETWEEN(c, 0x80, 0x9f))
#define ISCONTROL(c)		(ISCONTROLC0(c) || ISCONTROLC1(c))
#define ISDELIM(u)		(u && wcschr(worddelimiters, u))
#define TLINE(y)		((y) < term.scr ? term.hist[(int)((((y) + term.histi - term.scr + HISTSIZE + 1) % HISTSIZE))] : \
				term.line[(y) - term.scr])

enum term_mode {
	MODE_WRAP        = 1 << 0,
	MODE_INSERT      = 1 << 1,
	MODE_ALTSCREEN   = 1 << 2,
	MODE_CRLF        = 1 << 3,
	MODE_ECHO        = 1 << 4,
	MODE_PRINT       = 1 << 5,
	MODE_UTF8        = 1 << 6,
};

enum cursor_movement {
	CURSOR_SAVE,
	CURSOR_LOAD
};

enum cursor_state {
	CURSOR_DEFAULT  = 0,
	CURSOR_WRAPNEXT = 1,
	CURSOR_ORIGIN   = 2
};

enum charset {
	CS_GRAPHIC0,
	CS_GRAPHIC1,
	CS_UK,
	CS_USA,
	CS_MULTI,
	CS_GER,
	CS_FIN
};

enum escape_state {
	ESC_START      = 1,
	ESC_CSI        = 2,
	ESC_STR        = 4,  /* DCS, OSC, PM, APC */
	ESC_ALTCHARSET = 8,
	ESC_STR_END    = 16, /* a final string was encountered */
	ESC_TEST       = 32, /* Enter in test mode */
	ESC_UTF8       = 64,
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
	int row;      /* nb row */
	int col;      /* nb col */
	int maxcol;
	Line *line;   /* screen */
	Line *alt;    /* alternate screen */
	Line hist[HISTSIZE]; /* history buffer */
	int histi;    /* history index */
	int scr;      /* scroll back */
	int *dirty;   /* dirtyness of lines */
	TCursor c;    /* cursor */
	int ocx;      /* old cursor col */
	int ocy;      /* old cursor row */
	int top;      /* top    scroll limit */
	int bot;      /* bottom scroll limit */
	int mode;     /* terminal mode flags */
	int esc;      /* escape state flags */
	char trantbl[4]; /* charset table translation */
	int charset;  /* current charset */
	int icharset; /* selected charset for sequence */
	int *tabs;
	Rune lastc;   /* last printed char outside of sequence, 0 if control */
} Term;

/* CSI Escape sequence structs */
/* ESC '[' [[ [<priv>] <arg> [;]] <mode> [<mode>]] */
typedef struct {
	char buf[ESC_BUF_SIZ]; /* raw string */
	size_t len;            /* raw string length */
	char priv;
	int arg[ESC_ARG_SIZ];
	int narg;              /* nb of args */
	char mode[2];
} CSIEscape;

/* STR Escape sequence structs */
/* ESC type [[ [<priv>] <arg> [;]] <mode>] ESC '\' */
typedef struct {
	char type;             /* ESC type ... */
	char *buf;             /* allocated raw string */
	size_t siz;            /* allocation size */
	size_t len;            /* raw string length */
	char *args[STR_ARG_SIZ];
	int narg;              /* nb of args */
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
	int active;
	size_t len;
	size_t cursor;
	size_t cap;
} SearchInputState;

typedef struct {
	int count;
	int cap;
} SearchMatchesState;

static void execsh(char *, char **);
static void stty(char **);
static void sigchld(int);
static void ttywriteraw(const char *, size_t);
static SearchScalarState searchscalarstate(void);
static void searchwritescalarstate(SearchScalarState);
static ZigSearchSnapshot zigsearchsnapshot(SearchScalarState);
static SearchScalarState searchscalarfromupdate(ZigSearchStateUpdate);
static SearchInputState searchinputstate(void);
static void searchwriteinputstate(SearchInputState);
static void searchapplyqueryreplace(Rune *, ZigSearchSetResult);
static SearchMatchesState searchmatchesstate(void);
static void searchwritematchesstate(SearchMatchesState);
static void searchapplyinputinsert(ZigSearchInputResult, const char *, size_t);
static void searchapplyinputdelete(size_t, size_t);
static void searchapplyinputclear(ZigSearchStateResult);
static Rune *searchallocquerybuffer(size_t);
static void searchapplydecodedquery(size_t, int, Rune *);

static void csidump(void);
static void csihandle(void);
static void csiparse(void);
static void csireset(void);
static int eschandle(uchar);
static void strdump(void);
static void strhandle(void);
static void strparse(void);
static void strreset(void);

static void tprinter(char *, size_t);
static void tdumpsel(void);
static void tdumpline(int);
static void tdump(void);
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
static void tsetattr(int *, int);
static void tsetchar(Rune, Glyph *, int, int);
static void tsetdirt(int, int);
static void termapplydirtyrange(ZigLineRange);
static void tsetscroll(int, int);
static void tswapscreen(void);
static void tsetmode(int, int, int *, int);
static int twrite(const char *, int, int);
static void tcontrolcode(uchar );
static void tdectest(char );
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
static void searchdelete(size_t, size_t);

static ZigSelectionSnapshot selectionsnapshot(void);
static void selectionapplystate(ZigSelectionStateUpdate);
static void selectionapplybounds(ZigSelectionStateUpdate);
static void selectionapplyresult(ZigSelectionStateResult);
static void selectionapplyscrollresult(ZigSelectionStateResult);

static void selnormalize(void);
static void selscroll(int, int);
static void selsnap(int *, int *, int);

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

ssize_t
xwrite(int fd, const char *s, size_t len)
{
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

void *
xmalloc(size_t len)
{
	void *p;

	if (!(p = malloc(len)))
		die("malloc: %s\n", strerror(errno));

	return p;
}

void *
xrealloc(void *p, size_t len)
{
	if ((p = realloc(p, len)) == NULL)
		die("realloc: %s\n", strerror(errno));

	return p;
}

char *
xstrdup(char *s)
{
	if ((s = strdup(s)) == NULL)
		die("strdup: %s\n", strerror(errno));

	return s;
}

size_t
utf8decode(const char *c, Rune *u, size_t clen)
{
	ZigUtf8Decode dec;

	dec = st_utf8decode((const unsigned char *)c, clen);
	*u = dec.rune;
	return dec.len;
}

size_t
utf8encode(Rune u, char *c)
{
	return st_utf8encode(u, (unsigned char *)c);
}

char *
base64dec(const char *src)
{
	return st_base64dec(src);
}

void
selinit(void)
{
	sel.mode = SEL_IDLE;
	sel.snap = 0;
	sel.ob.x = -1;
}

int
tlinelen(int y)
{
	return st_tlinelen((const ZigGlyph *)TLINE(y), term.col);
}

Line
tlinehist(int y)
{
	ZigHistoryLinePlan plan;

	plan = st_tlinehistplan(y, HISTSIZE, term.row);
	return plan.hist ? term.hist[plan.index] : term.line[plan.index];
}

void
selstart(int col, int row, int snap)
{
	ZigSelectionStateResult result;

	selclear();
	result = st_selstartupdate(selectionsnapshot(), col, row, snap,
		IS_SET(MODE_ALTSCREEN));
	selectionapplyresult(result);
}

void
selextend(int col, int row, int type, int done)
{
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

void
selnormalize(void)
{
	ZigSelectionStateResult result;
	int start_len, end_len;

	start_len = tlinelen(sel.ob.y < sel.oe.y ? sel.ob.y : sel.oe.y);
	end_len = tlinelen(sel.ob.y < sel.oe.y ? sel.oe.y : sel.ob.y);
	result = st_selnormalizeupdate(selectionsnapshot(), term.col,
		start_len, end_len);
	selectionapplybounds(result.update);

	selsnap(&sel.nb.x, &sel.nb.y, -1);
	selsnap(&sel.ne.x, &sel.ne.y, +1);
}

static ZigSelectionSnapshot
selectionsnapshot(void)
{
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

static void
selectionapplystate(ZigSelectionStateUpdate update)
{
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

static void
selectionapplybounds(ZigSelectionStateUpdate update)
{
	sel.nb.x = update.nb_x;
	sel.nb.y = update.nb_y;
	sel.ne.x = update.ne_x;
	sel.ne.y = update.ne_y;
}

static void
selectionapplyresult(ZigSelectionStateResult result)
{
	selectionapplystate(result.update);
	if (result.effect.dirty)
		tsetdirt(result.effect.top, result.effect.bot);
}

static void
selectionapplyscrollresult(ZigSelectionStateResult result)
{
	if (result.effect.clear)
		selclear();
	else
		selectionapplystate(result.update);
}

int
selected(int x, int y)
{
	return st_selected(selectionsnapshot(), x, y, IS_SET(MODE_ALTSCREEN));
}

int
searchmatch(int x, int y)
{
	SearchMatchesState matches;
	SearchScalarState state;

	state = searchscalarstate();
	matches = searchmatchesstate();
	return st_searchmatchlist((const ZigSearchMatch *)search.matches,
		matches.count, state.active, state.current, term.scr, x, y);
}

int
searchcurrent(int x, int y)
{
	SearchMatchesState matches;
	SearchScalarState state;

	state = searchscalarstate();
	matches = searchmatchesstate();
	return st_searchcurrentmatch((const ZigSearchMatch *)search.matches,
		matches.count, state.active, state.current, term.scr, x, y);
}

void
searchclear(const Arg *arg)
{
	(void)arg;
	searchresetstate();
	redraw();
}

int
searchinputactive(void)
{
	return searchscalarstate().inputmode;
}

int
searchbaractive(void)
{
	SearchScalarState state;

	state = searchscalarstate();
	return state.inputmode || state.active;
}

const char *
searchinputtext(void)
{
	return search.input ? search.input : "";
}

size_t
searchinputcursor(void)
{
	return searchscalarstate().inputcursor;
}

void
searchnext(const Arg *arg)
{
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

void
searchprev(const Arg *arg)
{
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

void
searchprompt(const Arg *arg)
{
	SearchInputState input;
	ZigSearchPromptResult result;

	(void)arg;
	result = st_searchpromptupdate(searchsnapshot());
	searchapplyupdate(result.update);
	input = searchinputstate();
	if (result.effect.alloc_input) {
		search.input = xmalloc(input.cap);
	}
	search.input[0] = '\0';
	searchapplyvieweffect(result.effect);
}

void
searchinput(const char *text, size_t len)
{
	ZigSearchInputResult result;

	result = st_searchinputupdate(searchsnapshot(), len);
	if (!result.effect.refresh_search)
		return;
	searchapplyinputinsert(result, text, len);
}

void
searchbackspace(void)
{
	searchapplycursor(ST_ZIG_SEARCH_CURSOR_ACTION_BACKSPACE);
}

void
searchdeleteforward(void)
{
	searchapplycursor(ST_ZIG_SEARCH_CURSOR_ACTION_DELETE_FORWARD);
}

void
searchdeleteword(void)
{
	searchapplycursor(ST_ZIG_SEARCH_CURSOR_ACTION_DELETE_WORD);
}

void
searchclearinput(void)
{
	searchapplystate(ST_ZIG_SEARCH_STATE_ACTION_CLEAR_INPUT);
}

void
searchmoveleft(void)
{
	searchapplycursor(ST_ZIG_SEARCH_CURSOR_ACTION_MOVE_LEFT);
}

void
searchmoveright(void)
{
	searchapplycursor(ST_ZIG_SEARCH_CURSOR_ACTION_MOVE_RIGHT);
}

void
searchhome(void)
{
	searchapplycursor(ST_ZIG_SEARCH_CURSOR_ACTION_HOME);
}

void
searchend(void)
{
	searchapplycursor(ST_ZIG_SEARCH_CURSOR_ACTION_END);
}

static ZigSearchSnapshot
zigsearchsnapshot(SearchScalarState state)
{
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

static void
searchwritescalarstate(SearchScalarState state)
{
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

static SearchScalarState
searchscalarstate(void)
{
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

static SearchScalarState
searchscalarfromupdate(ZigSearchStateUpdate update)
{
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

static SearchInputState
searchinputstate(void)
{
	return (SearchInputState){
		.active = search.inputmode,
		.len = search.inputlen,
		.cursor = search.inputcursor,
		.cap = search.inputcap,
	};
}

static void
searchwriteinputstate(SearchInputState state)
{
	search.inputmode = state.active;
	search.inputlen = state.len;
	search.inputcursor = state.cursor;
	search.inputcap = state.cap;
}

static SearchMatchesState
searchmatchesstate(void)
{
	return (SearchMatchesState){
		.count = search.nmatches,
		.cap = search.cap,
	};
}

static void
searchwritematchesstate(SearchMatchesState state)
{
	search.nmatches = state.count;
	search.cap = state.cap;
}

static ZigSearchSnapshot
searchsnapshot(void)
{
	return zigsearchsnapshot(searchscalarstate());
}

static void
searchapplyupdate(ZigSearchStateUpdate update)
{
	searchwritescalarstate(searchscalarfromupdate(update));
}

static void
searchapplyresourceeffect(ZigSearchEffectPlan effect)
{
	if (effect.clear_query) {
		free(search.query);
		search.query = NULL;
	}
	if (effect.clear_matches) {
		free(search.matches);
		search.matches = NULL;
	}
}

static void
searchapplyvieweffect(ZigSearchEffectPlan effect)
{
	if (effect.jump)
		searchjump();
	if (effect.redraw)
		redraw();
}

static void
searchapplyfloweffect(ZigSearchEffectPlan effect)
{
	if (effect.refresh_search)
		searchset(search.input ? search.input : "");
	else
		searchapplyvieweffect(effect);
}

static int
searchresetscanmatches(void)
{
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

static void
searchapplyqueryreplace(Rune *runes, ZigSearchSetResult result)
{
	/* query 指针本体仍由 C 持有，但替换时序收口到单一 helper，
	 * 避免 searchset() 同时展开 free/replace/scan/jump 的细节。 */
	searchapplyresourceeffect(result.effect);
	search.query = runes;
	searchapplyupdate(result.update);
	if (result.effect.refresh_search)
		searchscan();
	searchapplyvieweffect(result.effect);
}

static Rune *
searchallocquerybuffer(size_t query_len)
{
	ZigSearchSetResult result;

	result = st_searchsetupdate(searchsnapshot(), query_len, 0);
	return xmalloc(result.alloc_len * sizeof(Rune));
}

static void
searchapplydecodedquery(size_t query_len, int qlen, Rune *runes)
{
	ZigSearchSetResult result;

	result = st_searchsetupdate(searchsnapshot(), query_len, qlen);
	searchapplyqueryreplace(runes, result);
}

static void
searchapplyinputinsert(ZigSearchInputResult result, const char *text, size_t len)
{
	SearchInputState input;

	searchapplyupdate(result.update);
	input = searchinputstate();
	if (result.effect.realloc_input) {
		search.input = xrealloc(search.input, input.cap);
	}
	memmove(search.input + result.move_dst,
		search.input + result.move_src,
		result.move_len);
	memcpy(search.input + result.insert_at, text, len);
	search.input[input.len] = '\0';
	searchset(search.input);
}

static void
searchapplyinputdelete(size_t start, size_t end)
{
	SearchInputState input;
	ZigSearchDeletePlan plan;

	input = searchinputstate();
	plan = st_searchdeleteplan(start, end, input.len);
	if (!plan.run)
		return;
	memmove(search.input + start, search.input + end, input.len - end + 1);
	input.len = plan.new_len;
	searchwriteinputstate(input);
}

static void
searchapplyinputclear(ZigSearchStateResult result)
{
	SearchInputState input;

	searchapplyupdate(result.update);
	searchapplyresourceeffect(result.effect);
	input = searchinputstate();
	if (search.input && input.len == 0)
		search.input[0] = '\0';
	if (result.effect.clear_query && input.cap == 0) {
		free(search.input);
		search.input = NULL;
	}
	searchapplyfloweffect(result.effect);
}

static void
searchresetstate(void)
{
	free(search.query);
	free(search.input);
	free(search.matches);
	memset(&search, 0, sizeof(search));
	search.current = -1;
}

static void
searchapplycursor(int action)
{
	ZigSearchCursorResult result;

	result = st_searchcursorupdate(searchsnapshot(),
		(const unsigned char *)searchinputtext(), action);
	if (result.delete_start != result.delete_end)
		searchapplyinputdelete(result.delete_start, result.delete_end);
	searchapplyupdate(result.update);
	searchapplyfloweffect(result.effect);
}

size_t
searchprevchar(size_t cursor)
{
	SearchInputState input;
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

size_t
searchnextchar(size_t cursor)
{
	SearchInputState input;
	size_t next;

	input = searchinputstate();
	if (cursor >= input.len)
		return input.len;
	next = cursor + 1;
	while (next < input.len && (((unsigned char)search.input[next] & 0xc0) == 0x80))
		next++;
	return next;
}

void
searchdelete(size_t start, size_t end)
{
	searchapplyinputdelete(start, end);
}

void
searchcommit(void)
{
	searchapplystate(ST_ZIG_SEARCH_STATE_ACTION_COMMIT);
}

void
searchcancel(void)
{
	searchapplystate(ST_ZIG_SEARCH_STATE_ACTION_CANCEL);
}

static void
searchapplystate(int action)
{
	ZigSearchStateResult result;

	result = st_searchstateupdate(searchsnapshot(), action);
	searchapplyinputclear(result);
}

void
searchset(const char *query)
{
	Rune rune;
	size_t len, off, step;
	int qlen = 0;
	Rune *runes;

	len = strlen(query);
	runes = searchallocquerybuffer(len);
	for (off = 0; off < len; off += step) {
		step = utf8decode(query + off, &rune, len - off);
		if (step == 0)
			break;
		runes[qlen++] = rune;
	}
	searchapplydecodedquery(len, qlen, runes);
}

void
searchscan(void)
{
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

void
searchscanline(Line line, int scr, int y)
{
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
		step = st_searchscanlineiter((const ZigGlyph *)line, term.col,
			search.query, state.query_len, scanstate);
		if (step.kind == ST_ZIG_SEARCH_APPEND_SKIP)
			break;

		if (step.kind == ST_ZIG_SEARCH_APPEND_GROW) {
			matches.cap = step.state.cap;
			searchwritematchesstate(matches);
			search.matches = xrealloc(search.matches,
				matches.cap * sizeof(*search.matches));
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

Line
searchhistline(int scr)
{
	return term.hist[(int)(((term.histi - scr + HISTSIZE + 1) % HISTSIZE))];
}

void
searchjump(void)
{
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
	plan = st_searchjumpplan(state.active, state.current, matches.count,
		term.scr, match->scr);
	if (plan.run && term.scr != plan.new_scr) {
		term.scr = plan.new_scr;
		tfulldirt();
	}
}

void
selsnap(int *x, int *y, int direction)
{
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
		prevrune = TLINE(*y)[*x].u;
		prevdelim = ISDELIM(prevrune);
		for (;;) {
			word_request = st_selsnapworditerrequest(*x, *y, direction,
				term.col, term.row, prevdelim, prevrune);
			if (word_request.action == ST_ZIG_SEL_SNAP_WORD_ITER_STOP)
				break;

			wrap_allowed = !word_request.wrapped ||
				(TLINE(word_request.wrap_y)[word_request.wrap_x].mode & ATTR_WRAP);
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
			word_step = st_selsnapworditerresolve(word_request, prevdelim,
				prevrune, word_reader);
			if (word_step.action == ST_ZIG_SEL_SNAP_WORD_BREAK)
				break;

			*x = word_step.x;
			*y = word_step.y;
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
		*x = st_selsnaplinex(direction, term.col);
		if (direction < 0) {
			for (;;) {
				line_step = st_selsnaplinestep(*y, direction,
					term.row, *y > 0 &&
					(TLINE(*y-1)[term.col-1].mode & ATTR_WRAP));
				if (line_step.action == ST_ZIG_SEL_SNAP_LINE_STOP)
					break;
				*y = line_step.y;
			}
		} else if (direction > 0) {
			for (;;) {
				line_step = st_selsnaplinestep(*y, direction,
					term.row, *y < term.row-1 &&
					(TLINE(*y)[term.col-1].mode & ATTR_WRAP));
				if (line_step.action == ST_ZIG_SEL_SNAP_LINE_STOP)
					break;
				*y = line_step.y;
			}
		}
		break;
	}
}

char *
getsel(void)
{
	char *str, *ptr;
	int y;
	Glyph *gp, *last;
	ZigGetSelExecPlan plan;

	if (sel.ob.x == -1)
		return NULL;

	plan = st_getselexecplan(selectionsnapshot(), sel.nb.y, term.col,
		(const ZigGlyph *)TLINE(sel.nb.y), UTF_SIZ);
	ptr = str = xmalloc(plan.bufsize);

	/* append every set & selected glyph to the selection */
	for (y = sel.nb.y; y <= sel.ne.y; y++) {
		plan = st_getselexecplan(selectionsnapshot(), y, term.col,
			(const ZigGlyph *)TLINE(y), UTF_SIZ);
		if (plan.empty) {
			*ptr++ = '\n';
			continue;
		}

		gp = &TLINE(y)[plan.start_x];
		last = &TLINE(y)[plan.last_index];

		for ( ; gp <= last; ++gp) {
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

void
selclear(void)
{
	if (!st_selclearplan(sel.ob.x))
		return;
	sel.mode = SEL_IDLE;
	sel.ob.x = -1;
	tsetdirt(sel.nb.y, sel.ne.y);
}

void
die(const char *errstr, ...)
{
	va_list ap;

	va_start(ap, errstr);
	vfprintf(stderr, errstr, ap);
	va_end(ap);
	exit(1);
}

void
execsh(char *cmd, char **args)
{
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
	DEFAULT(args, ((char *[]) {prog, arg, NULL}));

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

void
sigchld(int a)
{
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

void
stty(char **args)
{
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

int
ttynew(char *line, char *cmd, char *out, char **args)
{
	int m, s;

	if (out) {
		term.mode |= MODE_PRINT;
		iofd = (!strcmp(out, "-")) ?
			  1 : open(out, O_WRONLY | O_CREAT, 0666);
		if (iofd < 0) {
			fprintf(stderr, "Error opening %s:%s\n",
				out, strerror(errno));
		}
	}

	if (line) {
		if ((cmdfd = open(line, O_RDWR)) < 0)
			die("open line '%s' failed: %s\n",
			    line, strerror(errno));
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

size_t
ttyread(void)
{
	static char buf[BUFSIZ];
	static int buflen = 0;
	int ret, written;

	/* append read bytes to unprocessed bytes */
	ret = read(cmdfd, buf+buflen, LEN(buf)-buflen);

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

void
ttywrite(const char *s, size_t n, int may_echo)
{
	const char *next;
	Arg arg = (Arg) { .i = term.scr };

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

void
ttywriteraw(const char *s, size_t n)
{
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
		if (pselect(cmdfd+1, &rfd, &wfd, NULL, NULL, NULL) < 0) {
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

void
ttyresize(int tw, int th)
{
	struct winsize w;

	w.ws_row = term.row;
	w.ws_col = term.col;
	w.ws_xpixel = tw;
	w.ws_ypixel = th;
	if (ioctl(cmdfd, TIOCSWINSZ, &w) < 0)
		fprintf(stderr, "Couldn't set window size: %s\n", strerror(errno));
}

void
ttyhangup()
{
	/* Send SIGHUP to shell */
	kill(pid, SIGHUP);
}

int
tattrset(int attr)
{
	return st_tattrset((const ZigGlyph * const *)term.line,
		term.row, term.col, attr);
}

void
tsetdirt(int top, int bot)
{
	ZigLineRange range;

	range = st_tsetdirtrange(top, bot, term.row);
	termapplydirtyrange(range);
}

static void
termapplydirtyrange(ZigLineRange range)
{
	int i;

	for (i = range.top; i <= range.bot; i++)
		term.dirty[i] = 1;
}

void
tsetdirtattr(int attr)
{
	int i;

	for (i = 0; i < term.row-1; i++) {
		if (st_tlineattrset((const ZigGlyph *)term.line[i],
			term.col, attr))
			tsetdirt(i, i);
	}
}

void
tfulldirt(void)
{
	tsetdirt(0, term.row-1);
}

void
tcursor(int mode)
{
	static TCursor c[2];
	ZigCursorStorePlan plan;

	plan = st_tcursorplan(mode, IS_SET(MODE_ALTSCREEN));
	if (plan.action == ST_ZIG_CURSOR_STORE_SAVE) {
		c[plan.slot] = term.c;
	} else if (plan.action == ST_ZIG_CURSOR_STORE_LOAD) {
		term.c = c[plan.slot];
		tmoveto(c[plan.slot].x, c[plan.slot].y);
	}
}

void
treset(void)
{
	uint i;
	ZigResetPlan plan;

	plan = st_tresetplan(defaultfg, defaultbg, term.row);
	term.c = (TCursor){{
		.mode = plan.cursor_attr_mode,
		.fg = plan.cursor_fg,
		.bg = plan.cursor_bg
	}, .x = plan.cursor_x, .y = plan.cursor_y, .state = plan.cursor_state};

	st_tresettabs(term.tabs, term.col, tabspaces);
	term.top = plan.top;
	term.bot = plan.bot;
	term.mode = plan.mode;
	memset(term.trantbl, plan.trantbl, sizeof(term.trantbl));
	term.charset = plan.charset;

	for (i = 0; i < 2; i++) {
		tmoveto(0, 0);
		tcursor(CURSOR_SAVE);
		tclearregion(0, 0, term.col-1, term.row-1);
		tswapscreen();
	}
}

void
tnew(int col, int row)
{
	term = (Term){ .c = { .attr = { .fg = defaultfg, .bg = defaultbg } } };
	tresize(col, row);
	treset();
}

void
tswapscreen(void)
{
	Line *tmp = term.line;

	term.line = term.alt;
	term.alt = tmp;
	term.mode ^= MODE_ALTSCREEN;
	tfulldirt();
}

void
kscrolldown(const Arg* a)
{
	ZigKScrollPlan plan;

	plan = st_kscrolldownplan(a->i, term.row, term.scr);
	if (plan.run) {
		term.scr = plan.new_scr;
		selscroll(0, plan.delta);
		tfulldirt();
	}
}

void
kscrollup(const Arg* a)
{
	ZigKScrollPlan plan;

	plan = st_kscrollupplan(a->i, term.row, term.scr, HISTSIZE);
	if (plan.run) {
		term.scr = plan.new_scr;
		selscroll(0, plan.delta);
		tfulldirt();
	}
}

void
tscrolldown(int orig, int n, int copyhist)
{
	int i;
	Line temp;
	ZigScrollPlan plan;

	plan = st_tscrollplan(n, orig, term.bot, term.scr, HISTSIZE, 0,
		copyhist, term.histi);
	n = plan.count;

	if (copyhist) {
		term.histi = plan.new_histi;
		temp = term.hist[term.histi];
		term.hist[term.histi] = term.line[term.bot];
		term.line[term.bot] = temp;
	}

	tsetdirt(orig, term.bot-n);
	tclearregion(0, term.bot-n+1, term.col-1, term.bot);

	for (i = term.bot; i >= orig+n; i--) {
		temp = term.line[i];
		term.line[i] = term.line[i-n];
		term.line[i-n] = temp;
	}

	if (term.scr == 0)
		selscroll(orig, n);
}

void
tscrollup(int orig, int n, int copyhist)
{
	int i;
	Line temp;
	ZigScrollPlan plan;

	plan = st_tscrollplan(n, orig, term.bot, term.scr, HISTSIZE, 1,
		copyhist, term.histi);
	n = plan.count;

	if (copyhist) {
		term.histi = plan.new_histi;
		temp = term.hist[term.histi];
		term.hist[term.histi] = term.line[orig];
		term.line[orig] = temp;
	}

	term.scr = plan.new_scr;

	tclearregion(0, orig, term.col-1, orig+n-1);
	tsetdirt(orig+n, term.bot);

	for (i = orig; i <= term.bot-n; i++) {
		temp = term.line[i];
		term.line[i] = term.line[i+n];
		term.line[i+n] = temp;
	}

	if (term.scr == 0)
		selscroll(orig, -n);
}

void
selscroll(int orig, int n)
{
	ZigSelectionStateResult result;

	result = st_selscrollupdate(selectionsnapshot(), orig, term.top, term.bot, n);
	selectionapplyscrollresult(result);
}

void
tnewline(int first_col)
{
	ZigNewlinePlan plan;

	plan = st_tnewline(first_col, term.c.x, term.c.y, term.top, term.bot);
	if (plan.scroll)
		tscrollup(plan.scroll_top, 1, 1);
	tmoveto(plan.x, plan.y);
}

void
csiparse(void)
{
	ZigCsiParse parsed;

	parsed = st_csiparse((const unsigned char *)csiescseq.buf, csiescseq.len);
	csiescseq.priv = parsed.priv != 0;
	csiescseq.narg = parsed.narg;
	memcpy(csiescseq.arg, parsed.arg, sizeof(parsed.arg));
	csiescseq.mode[0] = parsed.mode[0];
	csiescseq.mode[1] = parsed.mode[1];
}

/* for absolute user moves, when decom is set */
void
tmoveato(int x, int y)
{
	if (IS_SET(CURSOR_ORIGIN))
		y += term.top;
	tmoveto(x, y);
}

void
tmoveto(int x, int y)
{
	ZigCursorMove move;

	move = st_tmoveto(x, y, term.c.state, term.col, term.row,
		term.top, term.bot);
	term.c.state = move.state;
	term.c.x = move.x;
	term.c.y = move.y;
}

void
tsetchar(Rune u, Glyph *attr, int x, int y)
{
	st_tsetchar(u, (const ZigGlyph *)attr, (ZigGlyph *)term.line[y],
		&term.dirty[y], x, term.col, term.trantbl[term.charset]);
	if (isboxdraw(term.line[y][x].u))
		term.line[y][x].mode |= ATTR_BOXDRAW;
}

void
tclearregion(int x1, int y1, int x2, int y2)
{
	int x, y;
	ZigClearRect rect;
	Glyph *gp;

	rect = st_tclearregionrect(x1, y1, x2, y2, term.maxcol, term.row);
	x1 = rect.x1;
	y1 = rect.y1;
	x2 = rect.x2;
	y2 = rect.y2;

	for (y = y1; y <= y2; y++) {
		term.dirty[y] = 1;
		for (x = x1; x <= x2; x++) {
			if (selected(x, y))
				selclear();
			gp = &term.line[y][x];
			st_tclearglyph((ZigGlyph *)gp, 0, (const ZigGlyph *)&term.c.attr);
		}
	}
}

void
tdeletechar(int n)
{
	ZigEditMove move;
	Glyph *line;

	move = st_tdeletechar(n, term.c.x, term.col);
	line = term.line[term.c.y];

	memmove(&line[move.dst], &line[move.src], move.size * sizeof(Glyph));
	tclearregion(move.clear_x1, term.c.y, move.clear_x2, term.c.y);
}

void
tinsertblank(int n)
{
	ZigEditMove move;
	Glyph *line;

	move = st_tinsertblank(n, term.c.x, term.col);
	line = term.line[term.c.y];

	memmove(&line[move.dst], &line[move.src], move.size * sizeof(Glyph));
	tclearregion(move.clear_x1, term.c.y, move.clear_x2, term.c.y);
}

void
tinsertblankline(int n)
{
	if (term.top <= term.c.y && term.c.y <= term.bot)
		tscrolldown(term.c.y, n, 0);
}

void
tdeleteline(int n)
{
	if (term.top <= term.c.y && term.c.y <= term.bot)
		tscrollup(term.c.y, n, 0);
}

void
tsetattr(int *attr, int l)
{
	ZigAttrUpdate update;

	update = st_tsetattr(
		(ZigAttrState){
			.mode = term.c.attr.mode,
			.fg = term.c.attr.fg,
			.bg = term.c.attr.bg,
		},
		defaultfg,
		defaultbg,
		attr,
		l
	);

	term.c.attr.mode = update.state.mode;
	term.c.attr.fg = update.state.fg;
	term.c.attr.bg = update.state.bg;

	switch (update.color_error.kind) {
	case ST_ZIG_COLOR_BAD_COUNT:
		fprintf(stderr,
			"erresc(38): Incorrect number of parameters (%d)\n",
			update.color_error.input_npar);
		break;
	case ST_ZIG_COLOR_BAD_RGB:
		fprintf(stderr, "erresc: bad rgb color (%u,%u,%u)\n",
			update.color_error.r,
			update.color_error.g,
			update.color_error.b);
		break;
	case ST_ZIG_COLOR_BAD_INDEX:
		fprintf(stderr, "erresc: bad fgcolor %d\n", update.color_error.value);
		break;
	case ST_ZIG_COLOR_UNKNOWN:
		fprintf(stderr,
		        "erresc(38): gfx attr %d unknown\n", update.color_error.value);
		break;
	}

	if (update.error_kind == ST_ZIG_ATTR_ERROR_UNKNOWN) {
		fprintf(stderr,
			"erresc(default): gfx attr %d unknown\n",
			update.error_value);
		csidump();
	}
}

void
tsetscroll(int t, int b)
{
	ZigScrollRegion region;

	region = st_tsetscroll(t, b, term.row);
	term.top = region.top;
	term.bot = region.bottom;
}

void
tapplyerase(const ZigErasePlan *plan)
{
	int i;

	for (i = 0; i < plan->count; ++i) {
		tclearregion(
			plan->rects[i].x1,
			plan->rects[i].y1,
			plan->rects[i].x2,
			plan->rects[i].y2
		);
	}
}

void
tapplycursor(const ZigCursorPlan *plan)
{
	switch (plan->kind) {
	case ST_ZIG_CURSOR_MOVE_TO:
		tmoveto(plan->x, plan->y);
		break;
	case ST_ZIG_CURSOR_MOVE_TO_ABS:
		tmoveato(plan->x, plan->y);
		break;
	}
}

void
tapplyedit(const ZigEditPlan *plan)
{
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
		tclearregion(plan->rect.x1, plan->rect.y1,
			plan->rect.x2, plan->rect.y2);
		break;
	case ST_ZIG_EDIT_DELETE_CHAR:
		tdeletechar(plan->count);
		break;
	}
}

void
tapplylight(const ZigLightPlan *plan, char *buf, int *len)
{
	switch (plan->kind) {
	case ST_ZIG_LIGHT_CLEAR_TAB_CURRENT:
		term.tabs[term.c.x] = 0;
		break;
	case ST_ZIG_LIGHT_CLEAR_TAB_ALL:
		memset(term.tabs, 0, term.col * sizeof(*term.tabs));
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
}

void
tapplystate(const ZigStatePlan *plan)
{
	switch (plan->kind) {
	case ST_ZIG_STATE_SET_SCROLL:
		tsetscroll(plan->top, plan->bottom);
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

void
tapplymisc(const ZigMiscPlan *plan)
{
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
		term.mode &= ~MODE_PRINT;
		break;
	case ST_ZIG_MISC_MEDIA_PRINT_ON:
		term.mode |= MODE_PRINT;
		break;
	case ST_ZIG_MISC_REPEAT_LAST:
		if (!term.lastc)
			break;
		for (count = plan->value; count > 0; --count)
			tputc(term.lastc);
		break;
	}
}

void
tsetmode(int priv, int set, int *args, int narg)
{
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
			if (plan.cursor_state_action == ST_ZIG_CURSOR_STATE_ORIGIN)
				MODBIT(term.c.state, plan.cursor_state_set, CURSOR_ORIGIN);
			if (plan.move_origin_home)
				tmoveato(0, 0);
			break;
		case ST_ZIG_MODE_WRAP:
			if (plan.term_mode_action == ST_ZIG_TERM_MODE_WRAP)
				MODBIT(term.mode, plan.term_mode_set, MODE_WRAP);
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
				tclearregion(0, 0, term.col-1, term.row-1);
			if (plan.swap_screen)
				tswapscreen();
			if (plan.cursor_after >= 0)
				tcursor(plan.cursor_after);
			break;
		case ST_ZIG_MODE_ALT47:
			if (!allowaltscreen)
				break;
			if (plan.clear_before_swap)
				tclearregion(0, 0, term.col-1, term.row-1);
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
			if (plan.term_mode_action == ST_ZIG_TERM_MODE_INSERT)
				MODBIT(term.mode, plan.term_mode_set, MODE_INSERT);
			break;
		case ST_ZIG_MODE_ECHO:
			if (plan.term_mode_action == ST_ZIG_TERM_MODE_ECHO)
				MODBIT(term.mode, plan.term_mode_set, MODE_ECHO);
			break;
		case ST_ZIG_MODE_CRLF:
			if (plan.term_mode_action == ST_ZIG_TERM_MODE_CRLF)
				MODBIT(term.mode, plan.term_mode_set, MODE_CRLF);
			break;
		case ST_ZIG_MODE_PRIVATE_UNKNOWN:
			fprintf(stderr,
				"erresc: unknown private set/reset mode %d\n",
				*args);
			break;
		case ST_ZIG_MODE_REGULAR_UNKNOWN:
			fprintf(stderr,
				"erresc: unknown set/reset mode %d\n",
				*args);
			break;
		}
	}
}

void
csihandle(void)
{
	char buf[40];
	int len;
	ZigCsiExecPlan plan;

	plan = st_csiexecplan(csiescseq.mode[0], csiescseq.mode[1],
		csiescseq.priv, csiescseq.arg, csiescseq.narg,
		term.c.x, term.c.y, term.col, term.row);

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
		tsetmode(csiescseq.priv, plan.mode_set,
			csiescseq.arg, csiescseq.narg);
		break;
	case ST_ZIG_CSI_EXEC_ATTR:
		tsetattr(csiescseq.arg, csiescseq.narg);
		break;
	case ST_ZIG_CSI_EXEC_STATE:
		tapplystate(&plan.state);
		break;
	}
}

void
csidump(void)
{
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

void
csireset(void)
{
	memset(&csiescseq, 0, sizeof(csiescseq));
}

void
strhandle(void)
{
	ZigStrHandlePlan plan;
	char *p = NULL, *dec;
	int j, narg, par;

	term.esc &= ~(ESC_STR_END|ESC_STR);
	strparse();
	par = (narg = strescseq.narg) ? atoi(strescseq.args[0]) : 0;
	plan = st_strhandleplan(strescseq.type, narg, par, allowwindowops);

	switch (plan.kind) {
	case 1:
		xsettitle(strescseq.args[1]);
		xseticontitle(strescseq.args[1]);
		return;
	case 2:
		xseticontitle(strescseq.args[1]);
		return;
	case 3:
		xsettitle(strescseq.args[1]);
		return;
	case 4:
		xsettitle(strescseq.args[0]);
		return;
	case 5:
		return;
	case 0:
		if (plan.clipboard_run) {
			dec = base64dec(strescseq.args[2]);
			if (dec) {
				xsetsel(dec);
				xclipcopy();
			} else {
				fprintf(stderr, "erresc: invalid base64\n");
			}
		}
		return;
	case 7:
		p = strescseq.args[2];
		j = plan.arg1_present ? atoi(strescseq.args[1]) : -1;
		if (xsetcolorname(j, p)) {
			fprintf(stderr, "erresc: invalid color j=%d, p=%s\n",
			        j, p ? p : "(null)");
		} else {
			redraw();
		}
		return;
	case 8:
		j = plan.arg1_present ? atoi(strescseq.args[1]) : -1;
		if (xsetcolorname(j, p)) {
			if (!plan.arg1_present)
				return;
			fprintf(stderr, "erresc: invalid color j=%d, p=%s\n",
			        j, p ? p : "(null)");
		} else {
			redraw();
		}
		return;
	case 6:
		fprintf(stderr, "erresc: unknown str ");
		strdump();
		return;
	}

	switch (strescseq.type) {
	}

	fprintf(stderr, "erresc: unknown str ");
	strdump();
}

void
strparse(void)
{
	ZigStrParse parsed;
	char *p;
	int i;
	size_t start;

	strescseq.buf[strescseq.len] = '\0';
	strescseq.narg = 0;

	if (*strescseq.buf == '\0')
		return;

	parsed = st_strparse((const unsigned char *)strescseq.buf, strescseq.len);
	strescseq.narg = parsed.narg;
	start = 0;
	for (i = 0; i < strescseq.narg; ++i) {
		strescseq.args[i] = &strescseq.buf[start];
		p = &strescseq.buf[parsed.ends[i]];
		if (*p == ';')
			*p = '\0';
		start = parsed.ends[i] + 1;
	}
}

void
externalpipe(const Arg *arg)
{
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

void
strdump(void)
{
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

void
strreset(void)
{
	strescseq = (STREscape){
		.buf = xrealloc(strescseq.buf, STR_BUF_SIZ),
		.siz = STR_BUF_SIZ,
	};
}

void
sendbreak(const Arg *arg)
{
	if (tcsendbreak(cmdfd, 0))
		perror("Error sending break");
}

void
tprinter(char *s, size_t len)
{
	if (iofd != -1 && xwrite(iofd, s, len) < 0) {
		perror("Error writing to output file");
		close(iofd);
		iofd = -1;
	}
}

void
toggleprinter(const Arg *arg)
{
	term.mode ^= MODE_PRINT;
}

void
printscreen(const Arg *arg)
{
	tdump();
}

void
printsel(const Arg *arg)
{
	tdumpsel();
}

void
tdumpsel(void)
{
	char *ptr;

	if ((ptr = getsel())) {
		tprinter(ptr, strlen(ptr));
		free(ptr);
	}
}

void
tdumpline(int n)
{
	char buf[UTF_SIZ];
	Glyph *bp, *end;
	ZigDumpLinePlan plan;

	bp = &term.line[n][0];
	plan = st_tdumplineplan(tlinelen(n), term.col);
	if (plan.write) {
		end = &bp[plan.last];
		for ( ; bp <= end; ++bp)
			tprinter(buf, utf8encode(bp->u, buf));
	}
	tprinter("\n", 1);
}

void
tdump(void)
{
	int i;

	for (i = 0; i < term.row; ++i)
		tdumpline(i);
}

void
tputtab(int n)
{
	term.c.x = st_tputtab(term.c.x, term.col, n, term.tabs);
}

void
tdefutf8(char ascii)
{
	switch (ascii) {
	case 'G':
		term.mode |= MODE_UTF8;
		break;
	case '@':
		term.mode &= ~MODE_UTF8;
		break;
	}
}

void
tdeftran(char ascii)
{
	int charset;

	switch (ascii) {
	case '0':
		charset = CS_GRAPHIC0;
		break;
	case 'B':
		charset = CS_USA;
		break;
	default:
		charset = -1;
		break;
	}
	if (charset < 0) {
		fprintf(stderr, "esc unhandled charset: ESC ( %c\n", ascii);
	} else {
		term.trantbl[term.icharset] = charset;
	}
}

void
tdectest(char c)
{
	int x, y;

	if (c == '8') { /* DEC screen alignment test. */
		for (x = 0; x < term.col; ++x) {
			for (y = 0; y < term.row; ++y)
				tsetchar('E', &term.c.attr, x, y);
		}
	}
}

void
tstrsequence(uchar c)
{
	ZigStrSequence seq;

	seq = st_tstrsequence(c, term.esc);
	strreset();
	strescseq.type = seq.seq_type;
	term.esc = seq.esc;
}

void
tcontrolcode(uchar ascii)
{
	ZigInputControlPlan plan = st_inputcontrolplan(ascii, term.esc,
		term.charset, term.c.x);

	if (plan.charset_set)
		term.charset = plan.charset;
	if (plan.tab_set)
		term.tabs[plan.tab_x] = 1;

	switch (plan.action) {
	case ST_ZIG_CTL_ACTION_TAB:
		tputtab(1);
		return;
	case ST_ZIG_CTL_ACTION_BACKSPACE:
		tmoveto(term.c.x-1, term.c.y);
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
		term.esc = plan.new_esc;
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
int
eschandle(uchar ascii)
{
	ZigInputEscPlan exec = st_inputescplan(ascii, term.esc, term.charset,
		term.icharset, term.c.x);
	ZigNewlinePlan plan;

	term.esc = exec.new_esc;
	if (exec.charset_set)
		term.charset = exec.charset;
	if (exec.icharset_set)
		term.icharset = exec.icharset;
	if (exec.tab_set)
		term.tabs[exec.tab_x] = 1;

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
		plan = st_treverseindex(term.c.x, term.c.y, term.top);
		if (plan.scroll)
			tscrolldown(plan.scroll_top, 1, 1);
		tmoveto(plan.x, plan.y);
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
		fprintf(stderr, "erresc: unknown sequence ESC 0x%02X '%c'\n",
			(uchar) ascii, isprint(ascii)? ascii:'.');
		break;
	}
	return exec.ret;
}

void
tputc(Rune u)
{
	char c[UTF_SIZ];
	ZigPutcDecode decoded;
	ZigPutcWriteResult write;
	ZigPutcPreparePlan prepare;
	ZigStrCollectExec collect_exec;
	ZigInputEscFlowPlan escflow;
	int control;
	int esc_action_done;
	int width, len;
	Glyph *gp;

	decoded = st_putcdecode(u, IS_SET(MODE_UTF8));
	control = decoded.control;
	width = decoded.width;
	len = decoded.len;
	memcpy(c, decoded.bytes, sizeof(decoded.bytes));

	if (IS_SET(MODE_PRINT))
		tprinter(c, len);

	/*
	 * STR sequence must be checked before anything else
	 * because it uses all following characters until it
	 * receives a ESC, a SUB, a ST or any other C1 control
	 * character.
	 */
	if (term.esc & ESC_STR) {
		collect_exec = st_tcollectstr(u, term.esc,
			(unsigned char *)strescseq.buf, strescseq.len,
			(const unsigned char *)c, len, strescseq.siz);
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
			collect_exec = st_tcollectstr(u, term.esc,
				(unsigned char *)strescseq.buf, strescseq.len,
				(const unsigned char *)c, len, strescseq.siz);
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
	if (control) {
		tcontrolcode(u);
		/*
		 * control codes are not shown ever
		 */
		if (term.esc == 0)
			term.lastc = 0;
		return;
	} else if (term.esc & ESC_START) {
		escflow = st_inputescflowplan(term.esc, u, csiescseq.len,
			sizeof(csiescseq.buf));
		esc_action_done = 1;
		switch (escflow.kind) {
		case ST_ZIG_ESC_FLOW_CSI:
			if (escflow.csi_write)
				csiescseq.buf[csiescseq.len] = escflow.csi_byte;
			csiescseq.len = escflow.new_csi_len;
			esc_action_done = escflow.handle_csi;
			if (escflow.handle_csi) {
				csiparse();
				csihandle();
			}
			break;
		case ST_ZIG_ESC_FLOW_UTF8:
			tdefutf8(u);
			break;
		case ST_ZIG_ESC_FLOW_ALTCHARSET:
			tdeftran(u);
			break;
		case ST_ZIG_ESC_FLOW_TEST:
			tdectest(u);
			break;
		default:
			esc_action_done = eschandle(u);
			/* sequence already finished */
			break;
		}
		if ((escflow.kind == ST_ZIG_ESC_FLOW_CSI || escflow.kind == ST_ZIG_ESC_FLOW_ESC) && !esc_action_done)
			return;
		term.esc = 0;
		/*
		 * All characters which form part of a sequence are not
		 * printed
		 */
		return;
	}
	prepare = st_tputcprepare(selected(term.c.x, term.c.y),
		IS_SET(MODE_WRAP), term.c.state, term.c.x, width, term.col);
	if (prepare.clear_selection)
		selclear();

	gp = &term.line[term.c.y][term.c.x];
	if (prepare.wrapnext) {
		gp->mode |= ATTR_WRAP;
		tnewline(1);
		gp = &term.line[term.c.y][term.c.x];
	}

	if (prepare.overflow) {
		tnewline(1);
		gp = &term.line[term.c.y][term.c.x];
	}

	write = st_tputcwrite(u, width, (const ZigGlyph *)&term.c.attr,
		(ZigGlyph *)term.line[term.c.y], &term.dirty[term.c.y],
		term.c.x, term.col, term.trantbl[term.charset],
		IS_SET(MODE_INSERT));
	term.lastc = u;
	if (write.advance == ST_ZIG_PUTC_ADVANCE_MOVE) {
		tmoveto(write.next_x, term.c.y);
	} else {
		term.c.state |= CURSOR_WRAPNEXT;
	}
}

int
twrite(const char *buf, int buflen, int show_ctrl)
{
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

void
tresize(int col, int row)
{
	int i, j;
	TCursor cursor;
	ZigResizeExecPlan exec_plan;
	ZigResizePlan base;

	exec_plan = st_tresizeexecplan(term.tabs, col, row, term.col, term.row,
		term.maxcol, term.c.y, tabspaces);
	base = exec_plan.base;
	term.maxcol = base.base_maxcol;
	col = base.alloc_col;

	if (base.invalid) {
		fprintf(stderr,
		        "tresize: error resizing to %dx%d\n", col, row);
		return;
	}

	for (i = 0; i < base.slide_count; i++) {
		free(term.line[i]);
		free(term.alt[i]);
	}
	if (i > 0) {
		memmove(term.line, term.line + i, row * sizeof(Line));
		memmove(term.alt, term.alt + i, row * sizeof(Line));
	}
	for (i = base.tail_start; i < term.row; i++) {
		free(term.line[i]);
		free(term.alt[i]);
	}

	term.line = xrealloc(term.line, row * sizeof(Line));
	term.alt  = xrealloc(term.alt,  row * sizeof(Line));
	term.dirty = xrealloc(term.dirty, row * sizeof(*term.dirty));
	term.tabs = xrealloc(term.tabs, col * sizeof(*term.tabs));

	for (i = 0; i < HISTSIZE; i++) {
		term.hist[i] = xrealloc(term.hist[i], col * sizeof(Glyph));
		for (j = exec_plan.hist_fill.start;
				exec_plan.hist_fill.run && j < exec_plan.hist_fill.end; j++) {
			term.hist[i][j] = term.c.attr;
			term.hist[i][j].u = ' ';
		}
	}

	for (i = exec_plan.rows.resize_start; i < exec_plan.rows.resize_end; i++) {
		term.line[i] = xrealloc(term.line[i], col * sizeof(Glyph));
		term.alt[i]  = xrealloc(term.alt[i],  col * sizeof(Glyph));
	}

	for (i = exec_plan.rows.alloc_start; i < exec_plan.rows.alloc_end; i++) {
		term.line[i] = xmalloc(col * sizeof(Glyph));
		term.alt[i] = xmalloc(col * sizeof(Glyph));
	}

	if (exec_plan.tabs.grow) {
		memset(term.tabs + exec_plan.tabs.clear_start, 0,
		       sizeof(*term.tabs) * exec_plan.tabs.clear_count);
		for (i = exec_plan.tabs.tab_start;
				i < col; i += tabspaces)
			term.tabs[i] = 1;
	}

	term.col = base.requested_col;
	term.maxcol = col;
	term.row = row;
	tsetscroll(0, row-1);
	tmoveto(term.c.x, term.c.y);
	cursor = term.c;
	for (i = 0; i < 2; i++) {
		for (j = 0; j < exec_plan.clear.count; j++)
			tclearregion(exec_plan.clear.rects[j].x1, exec_plan.clear.rects[j].y1,
				exec_plan.clear.rects[j].x2, exec_plan.clear.rects[j].y2);
		tswapscreen();
		tcursor(CURSOR_LOAD);
	}
	term.c = cursor;
}

void
resettitle(void)
{
	xsettitle(NULL);
}

void
drawregion(int x1, int y1, int x2, int y2)
{
	int y = y1;
	ZigDrawRegionPlan region;

	for (;;) {
		region = st_drawregionplan(term.dirty, y, y2);
		if (!region.draw)
			break;
		y = region.y;
		term.dirty[y] = 0;
		xdrawline(TLINE(y), x1, y, x2);
		y = region.next_y;
	}
}

void
draw(void)
{
	int cursor_x = term.c.x;
	ZigDrawExecPlan frame;

	if (!xstartdraw())
		return;
	frame = st_drawexecplan(search.active, term.scr, cursor_x, term.c.y,
		term.ocx, term.ocy, term.col, term.row,
		(const ZigGlyph * const *)term.line, term.dirty, 0, term.row);
	if (frame.search_scan)
		searchscan();

	cursor_x = frame.cx;
	term.ocx = frame.ocx;
	term.ocy = frame.ocy;

	if (frame.region_draw)
		drawregion(0, frame.region_y, term.col, term.row);
	if (frame.cursor_active)
		xdrawcursor(cursor_x, term.c.y, term.line[term.c.y][cursor_x],
				term.ocx, term.ocy, term.line[term.ocy][term.ocx],
				term.line[term.ocy], term.col);
	term.ocx = cursor_x;
	term.ocy = term.c.y;
	xfinishdraw();
	if (frame.imspot_active)
		xximspot(term.ocx, term.ocy);
}

void
redraw(void)
{
	tfulldirt();
	draw();
}
