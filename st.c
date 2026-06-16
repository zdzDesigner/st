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
#define TLINE(y)		((y) < term.scr ? term.hist[((y) + term.histi - \
				term.scr + HISTSIZE + 1) % HISTSIZE] : \
				term.line[(y) - term.scr])
#define TLINE_HIST(y)           ((y) <= HISTSIZE-term.row+2 ? term.hist[(y)] : term.line[(y-HISTSIZE+term.row-3)])

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

static void execsh(char *, char **);
static void stty(char **);
static void sigchld(int);
static void ttywriteraw(const char *, size_t);

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
static void searchjump(void);
static size_t searchprevchar(size_t);
static size_t searchnextchar(size_t);
static void searchdelete(size_t, size_t);

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

int
tlinehistlen(int y)
{
	return st_tlinelen((const ZigGlyph *)TLINE_HIST(y), term.col);
}

void
selstart(int col, int row, int snap)
{
	ZigSelStartPlan plan;

	selclear();
	plan = st_selstartplan(col, row, snap, IS_SET(MODE_ALTSCREEN));
	sel.mode = plan.mode;
	sel.type = plan.sel_type;
	sel.alt = plan.alt;
	sel.snap = plan.snap;
	sel.oe.x = sel.ob.x = plan.x;
	sel.oe.y = sel.ob.y = plan.y;
	selnormalize();

	sel.mode = plan.final_mode;
	tsetdirt(sel.nb.y, sel.ne.y);
}

void
selextend(int col, int row, int type, int done)
{
	int oldey, oldex, oldsby, oldsey, oldtype;
	ZigSelExtendPlan plan;

	if (sel.mode == SEL_IDLE)
		return;
	if (done && sel.mode == SEL_EMPTY) {
		selclear();
		return;
	}

	oldey = sel.oe.y;
	oldex = sel.oe.x;
	oldsby = sel.nb.y;
	oldsey = sel.ne.y;
	oldtype = sel.type;

	sel.oe.x = col;
	sel.oe.y = row;
	selnormalize();
	sel.type = type;

	plan = st_selextendplan(oldex, oldey, oldtype, oldsby, oldsey,
		sel.oe.x, sel.oe.y, sel.type, sel.nb.y, sel.ne.y,
		sel.mode, done);
	if (plan.dirty)
		tsetdirt(plan.top, plan.bot);

	sel.mode = plan.mode;
}

void
selnormalize(void)
{
	ZigSelBounds bounds;

	bounds = st_planselnormalize(sel.type, sel.ob.x, sel.ob.y,
		sel.oe.x, sel.oe.y);
	sel.nb.x = bounds.nb_x;
	sel.nb.y = bounds.nb_y;
	sel.ne.x = bounds.ne_x;
	sel.ne.y = bounds.ne_y;

	selsnap(&sel.nb.x, &sel.nb.y, -1);
	selsnap(&sel.ne.x, &sel.ne.y, +1);

	/* expand selection over line breaks */
	if (sel.type == SEL_RECTANGULAR)
		return;
	bounds = st_planselnormalizecols(sel.type, sel.nb.x, sel.ne.x,
		tlinelen(sel.nb.y), tlinelen(sel.ne.y), term.col);
	sel.nb.x = bounds.nb_x;
	sel.ne.x = bounds.ne_x;
}

int
selected(int x, int y)
{
	return st_selected(x, y, sel.mode, sel.ob.x, sel.alt,
		IS_SET(MODE_ALTSCREEN), sel.type, sel.nb.x, sel.nb.y,
		sel.ne.x, sel.ne.y);
}

int
searchmatch(int x, int y)
{
	int i;

	for (i = 0; i < search.nmatches; ++i) {
		if (st_searchhit(search.active, search.matches[i].scr, term.scr,
				search.matches[i].y, y, x, search.matches[i].x,
				search.matches[i].len))
			return 1;
	}

	return 0;
}

int
searchcurrent(int x, int y)
{
	SearchMatch *match;

	if (!st_searchcurrentvalid(search.active, search.current, search.nmatches))
		return 0;

	match = &search.matches[search.current];
	return st_searchhit(search.active, match->scr, term.scr, match->y, y,
		x, match->x, match->len);
}

void
searchclear(const Arg *arg)
{
	(void)arg;
	free(search.query);
	free(search.input);
	free(search.matches);
	memset(&search, 0, sizeof(search));
	search.current = -1;
	redraw();
}

int
searchinputactive(void)
{
	return search.inputmode;
}

int
searchbaractive(void)
{
	return st_searchbaractive(search.inputmode, search.active);
}

const char *
searchinputtext(void)
{
	return search.input ? search.input : "";
}

size_t
searchinputcursor(void)
{
	return search.inputcursor;
}

void
searchnext(const Arg *arg)
{
	ZigSearchStepPlan plan;

	(void)arg;
	searchscan();
	plan = st_searchstep(search.active, search.nmatches, search.current, 1);
	if (!plan.run)
		return;
	search.current = plan.current;
	searchjump();
	redraw();
}

void
searchprev(const Arg *arg)
{
	ZigSearchStepPlan plan;

	(void)arg;
	searchscan();
	plan = st_searchstep(search.active, search.nmatches, search.current, -1);
	if (!plan.run)
		return;
	search.current = plan.current;
	searchjump();
	redraw();
}

void
searchprompt(const Arg *arg)
{
	ZigSearchPromptPlan plan;

	(void)arg;
	plan = st_searchpromptplan(search.input != NULL, search.inputcap);
	search.inputmode = plan.inputmode;
	search.inputlen = plan.inputlen;
	search.inputcursor = plan.inputcursor;
	if (plan.alloc) {
		search.inputcap = plan.inputcap;
		search.input = xmalloc(search.inputcap);
	}
	search.input[0] = '\0';
	redraw();
}

void
searchinput(const char *text, size_t len)
{
	if (!st_searchinputplan(search.inputmode, len))
		return;

	if (st_searchinputgrow(search.inputlen, len, search.inputcap)) {
		search.inputcap = st_searchinputcap(search.inputlen, len,
			search.inputcap);
		search.input = xrealloc(search.input, search.inputcap);
	}
	memmove(search.input + search.inputcursor + len,
		search.input + search.inputcursor,
		search.inputlen - search.inputcursor + 1);
	memcpy(search.input + search.inputcursor, text, len);
	search.inputlen += len;
	search.inputcursor += len;
	search.input[search.inputlen] = '\0';
	searchset(search.input);
}

void
searchbackspace(void)
{
	size_t prev;

	if (!st_searchbackspaceplan(search.inputmode, search.inputlen,
		search.inputcursor))
		return;

	prev = searchprevchar(search.inputcursor);
	searchdelete(prev, search.inputcursor);
	search.inputcursor = prev;
	searchset(search.input);
}

void
searchdeleteforward(void)
{
	size_t next;

	if (!st_searchdeleteforwardplan(search.inputmode,
		search.inputcursor, search.inputlen))
		return;
	next = searchnextchar(search.inputcursor);
	searchdelete(search.inputcursor, next);
	searchset(search.input);
}

void
searchdeleteword(void)
{
	size_t start;

	if (!st_searchdeletewordplan(search.inputmode, search.inputcursor))
		return;
	start = st_searchdeletewordstart((const unsigned char *)search.input,
		search.inputcursor);
	searchdelete(start, search.inputcursor);
	search.inputcursor = start;
	searchset(search.input);
}

void
searchclearinput(void)
{
	if (!st_searchclearinputplan(search.inputmode))
		return;
	search.inputlen = 0;
	search.inputcursor = 0;
	if (search.input)
		search.input[0] = '\0';
	searchset(search.input);
}

void
searchmoveleft(void)
{
	if (!st_searchbackspaceplan(search.inputmode, search.inputlen,
		search.inputcursor))
		return;
	search.inputcursor = searchprevchar(search.inputcursor);
	redraw();
}

void
searchmoveright(void)
{
	if (!st_searchdeleteforwardplan(search.inputmode,
		search.inputcursor, search.inputlen))
		return;
	search.inputcursor = searchnextchar(search.inputcursor);
	redraw();
}

void
searchhome(void)
{
	if (!st_searchcursorplan(search.inputmode))
		return;
	search.inputcursor = 0;
	redraw();
}

void
searchend(void)
{
	if (!st_searchcursorplan(search.inputmode))
		return;
	search.inputcursor = search.inputlen;
	redraw();
}

size_t
searchprevchar(size_t cursor)
{
	return st_searchprevchar((const unsigned char *)search.input, cursor);
}

size_t
searchnextchar(size_t cursor)
{
	return st_searchnextchar((const unsigned char *)search.input, cursor,
		search.inputlen);
}

void
searchdelete(size_t start, size_t end)
{
	ZigSearchDeletePlan plan;

	plan = st_searchdeleteplan(start, end, search.inputlen);
	if (!plan.run)
		return;
	memmove(search.input + start, search.input + end, search.inputlen - end + 1);
	search.inputlen = plan.new_len;
}

void
searchcommit(void)
{
	int action;

	action = st_searchcommitplan(search.inputmode, search.inputlen);
	if (action == ST_ZIG_SEARCH_ACTION_NONE)
		return;

	search.inputmode = 0;
	if (action == ST_ZIG_SEARCH_ACTION_CLEAR) {
		searchclear(NULL);
		return;
	}
	searchset(search.input);
}

void
searchcancel(void)
{
	if (st_searchcancelplan(search.inputmode) == ST_ZIG_SEARCH_ACTION_NONE)
		return;

	search.inputmode = 0;
	redraw();
}

void
searchset(const char *query)
{
	Rune rune;
	size_t len, off, step;
	int qlen = 0;
	Rune *runes;
	ZigSearchSetPlan plan;

	len = strlen(query);
	plan = st_searchsetplan(len, 0);
	runes = xmalloc(plan.alloc_len * sizeof(*runes));
	for (off = 0; off < len; off += step) {
		step = utf8decode(query + off, &rune, len - off);
		if (step == 0)
			break;
		runes[qlen++] = rune;
	}

	free(search.query);
	plan = st_searchsetplan(len, qlen);
	search.query = runes;
	search.qlen = qlen;
	search.active = plan.active;
	search.current = plan.current;
	searchscan();
	searchjump();
	redraw();
}

void
searchscan(void)
{
	int y, scr, oldcurrent;

	oldcurrent = search.current;
	search.nmatches = 0;
	if (!st_searchscanplan(search.active, search.qlen))
		return;

	for (y = 0; y < term.row; ++y) {
		searchscanline(term.line[y], 0, y);
	}
	for (scr = 1; scr < HISTSIZE; ++scr) {
		searchscanline(searchhistline(scr), scr, 0);
	}

	search.current = st_searchnextcurrent(oldcurrent, search.nmatches);
}

void
searchscanline(Line line, int scr, int y)
{
	int x, linelen, matchlen;
	SearchMatch *match;

	linelen = st_tlinelen((const ZigGlyph *)line, term.col);
	for (x = 0; x <= linelen - search.qlen; ++x) {
		matchlen = st_searchlinematch((const ZigGlyph *)line, x,
			linelen, search.query, search.qlen, term.col);
		if (!matchlen)
			continue;

		if (search.nmatches == search.cap) {
			search.cap = st_searchmatchcap(search.nmatches, search.cap);
			search.matches = xrealloc(search.matches,
				search.cap * sizeof(*search.matches));
		}
		match = &search.matches[search.nmatches++];
		match->x = x;
		match->y = y;
		match->scr = scr;
		match->len = matchlen;
	}
}

Line
searchhistline(int scr)
{
	return term.hist[(term.histi - scr + HISTSIZE + 1) % HISTSIZE];
}

void
searchjump(void)
{
	SearchMatch *match;
	int nextscr;

	if (!st_searchcurrentvalid(search.active, search.current, search.nmatches))
		return;

	match = &search.matches[search.current];
	nextscr = st_searchjumpscr(1, term.scr, match->scr);
	if (term.scr != nextscr) {
		term.scr = nextscr;
		tfulldirt();
	}
}

void
selsnap(int *x, int *y, int direction)
{
	int newx, newy, xt, yt;
	int delim, prevdelim;
	Glyph *gp, *prevgp;

	switch (sel.snap) {
	case SNAP_WORD:
		/*
		 * Snap around if the word wraps around at the end or
		 * beginning of a line.
		 */
		prevgp = &TLINE(*y)[*x];
		prevdelim = ISDELIM(prevgp->u);
		for (;;) {
			newx = *x + direction;
			newy = *y;
			if (!BETWEEN(newx, 0, term.col - 1)) {
				newy += direction;
				newx = (newx + term.col) % term.col;
				if (!BETWEEN(newy, 0, term.row - 1))
					break;

				if (direction > 0)
					yt = *y, xt = *x;
				else
					yt = newy, xt = newx;
				if (!(TLINE(yt)[xt].mode & ATTR_WRAP))
					break;
			}

			if (newx >= tlinelen(newy))
				break;

			gp = &TLINE(newy)[newx];
			delim = ISDELIM(gp->u);
			if (!(gp->mode & ATTR_WDUMMY) && (delim != prevdelim
					|| (delim && gp->u != prevgp->u)))
				break;

			*x = newx;
			*y = newy;
			prevgp = gp;
			prevdelim = delim;
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
			for (; *y > 0; *y += direction) {
				if (!(TLINE(*y-1)[term.col-1].mode
						& ATTR_WRAP)) {
					break;
				}
			}
		} else if (direction > 0) {
			for (; *y < term.row-1; *y += direction) {
				if (!(TLINE(*y)[term.col-1].mode
						& ATTR_WRAP)) {
					break;
				}
			}
		}
		break;
	}
}

char *
getsel(void)
{
	char *str, *ptr;
	int y, bufsize, lastx, linelen;
	Glyph *gp, *last;
	ZigGetSelLinePlan line_plan;

	if (sel.ob.x == -1)
		return NULL;

	bufsize = st_getselbufsize(term.col, sel.nb.y, sel.ne.y, UTF_SIZ);
	ptr = str = xmalloc(bufsize);

	/* append every set & selected glyph to the selection */
	for (y = sel.nb.y; y <= sel.ne.y; y++) {
		if ((linelen = tlinelen(y)) == 0) {
			*ptr++ = '\n';
			continue;
		}

		line_plan = st_getsellineplan(sel.type, sel.nb.x, sel.nb.y,
			sel.ne.x, sel.ne.y, y, term.col);
		gp = &TLINE(y)[line_plan.start_x];
		lastx = line_plan.last_x;
		last = &TLINE(y)[st_getsellastx(lastx, linelen)];
		while (last >= gp && last->u == ' ')
			--last;

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
		if (st_getselnewline(y, sel.ne.y, lastx, linelen,
			last->mode, sel.type))
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

	if (!st_sttyfits((n = strlen(stty_args)), sizeof(cmd)))
		die("incorrect stty parameters\n");
	memcpy(cmd, stty_args, n);
	q = cmd + n;
	siz = sizeof(cmd) - n;
	for (p = args; p && (s = *p); ++p) {
		if (!st_sttyfits((n = strlen(s)), siz))
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
		if (st_ttyreadpending(buflen))
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
			next = s + st_ttywritechunk((const unsigned char *)s, n);
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
			if ((r = write(cmdfd, s, st_ttywritecount(n, lim))) < 0)
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
	int i;
	ZigLineRange range;

	range = st_tsetdirtrange(top, bot, term.row);
	top = range.top;
	bot = range.bot;

	for (i = top; i <= bot; i++)
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
	term.mode = st_tswapscreenmode(term.mode);
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

	plan = st_tscrollplan(n, orig, term.bot, term.scr, HISTSIZE, 0);
	n = plan.count;

	if (copyhist) {
		term.histi = (term.histi - 1 + HISTSIZE) % HISTSIZE;
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

	if (st_tscrollselplan(term.scr))
		selscroll(orig, n);
}

void
tscrollup(int orig, int n, int copyhist)
{
	int i;
	Line temp;
	ZigScrollPlan plan;

	plan = st_tscrollplan(n, orig, term.bot, term.scr, HISTSIZE, 1);
	n = plan.count;

	if (copyhist) {
		term.histi = (term.histi + 1) % HISTSIZE;
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

	if (st_tscrollselplan(term.scr))
		selscroll(orig, -n);
}

void
selscroll(int orig, int n)
{
	ZigSelScrollPlan plan;

	plan = st_selscrollplan(sel.ob.x, sel.ob.y, sel.oe.y,
		sel.nb.y, sel.ne.y, orig, term.top, term.bot, n);
	if (plan.action == ST_ZIG_SEL_SCROLL_CLEAR) {
		selclear();
	} else if (plan.action == ST_ZIG_SEL_SCROLL_NORMALIZE) {
		sel.ob.y = plan.ob_y;
		sel.oe.y = plan.oe_y;
		selnormalize();
	}
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
	csiescseq.priv = st_csiprivbool(parsed.priv);
	csiescseq.narg = parsed.narg;
	memcpy(csiescseq.arg, parsed.arg, sizeof(parsed.arg));
	csiescseq.mode[0] = parsed.mode[0];
	csiescseq.mode[1] = parsed.mode[1];
}

/* for absolute user moves, when decom is set */
void
tmoveato(int x, int y)
{
	tmoveto(x, st_tmoveato_y(y, term.c.state, term.top));
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
	if (st_tlineinregion(term.c.y, term.top, term.bot))
		tscrolldown(term.c.y, n, 0);
}

void
tdeleteline(int n)
{
	if (st_tlineinregion(term.c.y, term.top, term.bot))
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
	int alt, *lim;

	for (lim = args + narg; args < lim; ++args) {
		plan = st_planmode(priv, *args);

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
			MODBIT(term.c.state, set, CURSOR_ORIGIN);
			tmoveato(0, 0);
			break;
		case ST_ZIG_MODE_WRAP:
			MODBIT(term.mode, set, MODE_WRAP);
			break;
		case ST_ZIG_MODE_CURSOR_VISIBILITY:
			xsetmode(!set, MODE_HIDE);
			break;
		case ST_ZIG_MODE_MOUSE_X10:
			xsetpointermotion(0);
			xsetmode(0, MODE_MOUSE);
			xsetmode(set, MODE_MOUSEX10);
			break;
		case ST_ZIG_MODE_MOUSE_BTN:
			xsetpointermotion(0);
			xsetmode(0, MODE_MOUSE);
			xsetmode(set, MODE_MOUSEBTN);
			break;
		case ST_ZIG_MODE_MOUSE_MOTION:
			xsetpointermotion(0);
			xsetmode(0, MODE_MOUSE);
			xsetmode(set, MODE_MOUSEMOTION);
			break;
		case ST_ZIG_MODE_MOUSE_MANY:
			xsetpointermotion(set);
			xsetmode(0, MODE_MOUSE);
			xsetmode(set, MODE_MOUSEMANY);
			break;
		case ST_ZIG_MODE_FOCUS:
			xsetmode(set, MODE_FOCUS);
			break;
		case ST_ZIG_MODE_MOUSE_SGR:
			xsetmode(set, MODE_MOUSESGR);
			break;
		case ST_ZIG_MODE_8BIT:
			xsetmode(set, MODE_8BIT);
			break;
		case ST_ZIG_MODE_ALT1049:
			if (!allowaltscreen)
				break;
			tcursor(st_tsetmodecursor(set));
			/* FALLTHROUGH */
		case ST_ZIG_MODE_ALT47:
			if (!allowaltscreen)
				break;
			alt = IS_SET(MODE_ALTSCREEN);
			if (alt) {
				tclearregion(0, 0, term.col-1, term.row-1);
			}
			if (st_tsetmodeswap(set, alt))
				tswapscreen();
			if (*args != 1049)
				break;
			/* FALLTHROUGH */
		case ST_ZIG_MODE_CURSOR1048:
			tcursor(st_tsetmodecursor(set));
			break;
		case ST_ZIG_MODE_BRACKETED_PASTE:
			xsetmode(set, MODE_BRCKTPASTE);
			break;
		case ST_ZIG_MODE_KBDLOCK:
			xsetmode(set, MODE_KBDLOCK);
			break;
		case ST_ZIG_MODE_INSERT:
			MODBIT(term.mode, set, MODE_INSERT);
			break;
		case ST_ZIG_MODE_ECHO:
			MODBIT(term.mode, !set, MODE_ECHO);
			break;
		case ST_ZIG_MODE_CRLF:
			MODBIT(term.mode, set, MODE_CRLF);
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
	ZigEditPlan edit;
	int len;
	ZigCursorPlan cursor;
	ZigErasePlan erase;
	ZigLightPlan light;
	ZigStatePlan state;
	ZigMiscPlan misc;

	switch (csiescseq.mode[0]) {
	default:
	unknown:
		fprintf(stderr, "erresc: unknown csi ");
		csidump();
		/* die(""); */
		break;
	case '@': /* ICH -- Insert <n> blank char */
	case 'S': /* SU -- Scroll <n> line up */
	case 'T': /* SD -- Scroll <n> line down */
	case 'L': /* IL -- Insert <n> blank lines */
	case 'M': /* DL -- Delete <n> lines */
	case 'X': /* ECH -- Erase <n> char */
	case 'P': /* DCH -- Delete <n> char */
		edit = st_planedit(csiescseq.mode[0], csiescseq.arg,
			csiescseq.narg, term.c.x, term.c.y);
		tapplyedit(&edit);
		break;
	case 'A': /* CUU -- Cursor <n> Up */
	case 'B': /* CUD -- Cursor <n> Down */
	case 'e': /* VPR --Cursor <n> Down */
	case 'C': /* CUF -- Cursor <n> Forward */
	case 'a': /* HPR -- Cursor <n> Forward */
	case 'D': /* CUB -- Cursor <n> Backward */
	case 'E': /* CNL -- Cursor <n> Down and first col */
	case 'F': /* CPL -- Cursor <n> Up and first col */
	case 'G': /* CHA -- Move to <col> */
	case '`': /* HPA */
	case 'H': /* CUP -- Move to <row> <col> */
	case 'f': /* HVP */
	case 'd': /* VPA -- Move to <row> */
		cursor = st_plancursor(csiescseq.mode[0], term.c.x, term.c.y,
			csiescseq.arg, csiescseq.narg);
		tapplycursor(&cursor);
		break;
	case 'i': /* MC -- Media Copy */
	case 'b': /* REP -- if last char is printable print it <n> more times */
	case ' ':
		misc = st_planmisc(csiescseq.mode[0], csiescseq.mode[1],
			csiescseq.arg, csiescseq.narg);
		if (misc.kind == ST_ZIG_MISC_UNKNOWN)
			goto unknown;
		if (misc.kind == ST_ZIG_MISC_SET_CURSOR_STYLE && xsetcursor(misc.value))
			goto unknown;
		tapplymisc(&misc);
		break;
	case 'c': /* DA -- Device Attributes */
	case 'g': /* TBC -- Tabulation clear */
	case 'I': /* CHT -- Cursor Forward Tabulation <n> tab stops */
	case 'Z': /* CBT -- Cursor Backward Tabulation <n> tab stops */
	case 'n': /* DSR - Device Status Report (cursor position) */
		light = st_planlight(csiescseq.mode[0], csiescseq.arg,
			csiescseq.narg, term.c.x, term.c.y);
		if (light.kind == ST_ZIG_LIGHT_UNKNOWN)
			goto unknown;
		tapplylight(&light, buf, &len);
		break;
	case 'J': /* ED -- Clear screen */
	case 'K': /* EL -- Clear line */
		erase = st_planerase(csiescseq.mode[0], csiescseq.arg[0],
			term.c.x, term.c.y,
			term.col, term.row);
		if (erase.kind != ST_ZIG_ERASE_OK)
			goto unknown;
		tapplyerase(&erase);
		break;
	case 'l': /* RM -- Reset Mode */
	case 'h': /* SM -- Set terminal mode */
		tsetmode(csiescseq.priv, csiescseq.mode[0] == 'h',
			csiescseq.arg, csiescseq.narg);
		break;
	case 'm': /* SGR -- Terminal attribute (color) */
		tsetattr(csiescseq.arg, csiescseq.narg);
		break;
	case 'r': /* DECSTBM -- Set Scrolling Region */
	case 's': /* DECSC -- Save cursor position (ANSI.SYS) */
	case 'u': /* DECRC -- Restore cursor position (ANSI.SYS) */
		state = st_planstate(csiescseq.mode[0], csiescseq.priv,
			csiescseq.arg, csiescseq.narg, term.row);
		if (state.kind == ST_ZIG_STATE_UNKNOWN) {
			goto unknown;
		}
		tapplystate(&state);
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
	plan = st_planstrhandle(strescseq.type, narg, par);

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
		if (st_strclipboardrun(narg, allowwindowops)) {
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
		j = st_strhasarg(narg, 1) ? atoi(strescseq.args[1]) : -1;
		if (xsetcolorname(j, p)) {
			fprintf(stderr, "erresc: invalid color j=%d, p=%s\n",
			        j, p ? p : "(null)");
		} else {
			redraw();
		}
		return;
	case 8:
		j = st_strhasarg(narg, 1) ? atoi(strescseq.args[1]) : -1;
		if (xsetcolorname(j, p)) {
			if (!st_strhasarg(narg, 1))
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
	ZigExternalPipeLinePlan line_plan;

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
	for (n = 0; n <= HISTSIZE + 2; n++) {
		bp = TLINE_HIST(n);
		line_plan = st_externalpipelinelen(tlinehistlen(n), term.col);
		if (line_plan.kind == ST_ZIG_EXTERNALPIPE_BREAK)
			break;
		if (line_plan.kind == ST_ZIG_EXTERNALPIPE_SKIP)
			continue;
		lastpos = line_plan.lastpos;
		end = &bp[lastpos + 1];
		for (; bp < end; ++bp)
			if (xwrite(to[1], buf, utf8encode(bp->u, buf)) < 0)
				break;
		if ((newline = st_externalpipewrap(TLINE_HIST(n)[lastpos].mode)))
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
	if (st_tprinterwrite(iofd) && xwrite(iofd, s, len) < 0) {
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
	term.mode = st_tdefutf8(term.mode, ascii);
}

void
tdeftran(char ascii)
{
	int charset;

	charset = st_tdeftran(ascii);
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

	if (st_tdectest(c)) { /* DEC screen alignment test. */
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
	ZigControlExec exec = st_tcontrolexec(ascii, &term.esc,
		&term.charset, term.tabs, term.c.x);

	switch (exec.action) {
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
	term.esc = st_tcontrolfinish(term.esc, exec.clear_str);
}

/*
 * returns 1 when the sequence is finished and it hasn't to read
 * more characters for this sequence, otherwise 0
 */
int
eschandle(uchar ascii)
{
	ZigEscExec exec = st_tescexec(ascii, &term.esc, &term.charset,
		&term.icharset, term.tabs, term.c.x);
	ZigNewlinePlan plan;

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
	ZigEscFlowExec escflow;
	ZigEscFlowAfter escafter;
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
		if (st_tcontrolafter(term.esc))
			term.lastc = 0;
		return;
	} else if (term.esc & ESC_START) {
		escflow = st_tescflow(term.esc, u, (unsigned char *)csiescseq.buf,
			csiescseq.len, sizeof(csiescseq.buf));
		esc_action_done = 1;
		switch (escflow.kind) {
		case ST_ZIG_ESC_FLOW_CSI:
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
		escafter = st_tescflowafter(escflow.kind, esc_action_done);
		if (escafter.stop && !escafter.clear_esc)
			return;
		if (escafter.clear_esc)
			term.esc = escafter.new_esc;
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
	int minrow, mincol;
	int *bp;
	TCursor c;
	ZigResizePlan plan;
	ZigResizeClearPlan clear_plan;

	plan = st_tresizeplan(col, row, term.col, term.row, term.maxcol, term.c.y);
	term.maxcol = plan.base_maxcol;
	col = plan.alloc_col;
	minrow = plan.minrow;
	mincol = plan.mincol;

	if (plan.invalid) {
		fprintf(stderr,
		        "tresize: error resizing to %dx%d\n", col, row);
		return;
	}

	/*
	 * slide screen to keep cursor where we expect it -
	 * tscrollup would work here, but we can optimize to
	 * memmove because we're freeing the earlier lines
	 */
	for (i = 0; i < plan.slide_count; i++) {
		free(term.line[i]);
		free(term.alt[i]);
	}
	/* ensure that both src and dst are not NULL */
	if (i > 0) {
		memmove(term.line, term.line + i, row * sizeof(Line));
		memmove(term.alt, term.alt + i, row * sizeof(Line));
	}
	for (i = plan.tail_start; i < term.row; i++) {
		free(term.line[i]);
		free(term.alt[i]);
	}

	/* resize to new height */
	term.line = xrealloc(term.line, row * sizeof(Line));
	term.alt  = xrealloc(term.alt,  row * sizeof(Line));
	term.dirty = xrealloc(term.dirty, row * sizeof(*term.dirty));
	term.tabs = xrealloc(term.tabs, col * sizeof(*term.tabs));

	for (i = 0; i < HISTSIZE; i++) {
		term.hist[i] = xrealloc(term.hist[i], col * sizeof(Glyph));
		for (j = mincol; j < col; j++) {
			term.hist[i][j] = term.c.attr;
			term.hist[i][j].u = ' ';
		}
	}

	/* resize each row to new width, zero-pad if needed */
	for (i = 0; i < plan.resize_rows; i++) {
		term.line[i] = xrealloc(term.line[i], col * sizeof(Glyph));
		term.alt[i]  = xrealloc(term.alt[i],  col * sizeof(Glyph));
	}

	/* allocate any new rows */
	for (i = plan.new_row_start; i < row; i++) {
		term.line[i] = xmalloc(col * sizeof(Glyph));
		term.alt[i] = xmalloc(col * sizeof(Glyph));
	}
	if (col > term.maxcol) {
		bp = term.tabs + term.maxcol;

		memset(bp, 0, sizeof(*term.tabs) * (col - term.maxcol));
		for (i = st_tresizetabstart(term.tabs, term.maxcol, tabspaces);
				i < col; i += tabspaces)
			term.tabs[i] = 1;
	}
	/* update terminal size */
	term.col = plan.requested_col;
	term.maxcol = col;
	term.row = row;
	/* reset scrolling region */
	tsetscroll(0, row-1);
	/* make use of the LIMIT in tmoveto */
	tmoveto(term.c.x, term.c.y);
	/* Clearing both screens (it makes dirty all lines) */
	c = term.c;
	for (i = 0; i < 2; i++) {
		clear_plan = st_tresizeclearplan(mincol, col, minrow, row);
		for (j = 0; j < clear_plan.count; j++)
			tclearregion(clear_plan.rects[j].x1, clear_plan.rects[j].y1,
				clear_plan.rects[j].x2, clear_plan.rects[j].y2);
		tswapscreen();
		tcursor(CURSOR_LOAD);
	}
	term.c = c;
}

void
resettitle(void)
{
	xsettitle(NULL);
}

void
drawregion(int x1, int y1, int x2, int y2)
{
	int y;

	for (y = y1; y < y2; y++) {
		if (!st_drawregionline(term.dirty[y]))
			continue;

		term.dirty[y] = 0;
		xdrawline(TLINE(y), x1, y, x2);
	}
}

void
draw(void)
{
	int cx = term.c.x, ocx = term.ocx, ocy = term.ocy;
	ZigDrawCursorPlan cursor;

	if (!xstartdraw())
		return;
	if (st_drawsearchscan(search.active))
		searchscan();

	/* adjust cursor position */
	cursor = st_drawcursorplan(cx, term.c.y, term.ocx, term.ocy,
		term.col, term.row, (const ZigGlyph * const *)term.line);
	cx = cursor.cx;
	term.ocx = cursor.ocx;
	term.ocy = cursor.ocy;

	drawregion(0, 0, term.col, term.row);
	if (st_drawcursoractive(term.scr))
		xdrawcursor(cx, term.c.y, term.line[term.c.y][cx],
				term.ocx, term.ocy, term.line[term.ocy][term.ocx],
				term.line[term.ocy], term.col);
	/* xdrawcursor(cx, term.c.y, term.line[term.c.y][cx], */
	/* 		term.ocx, term.ocy, term.line[term.ocy][term.ocx], */
	/* 		term.line[term.ocy], term.col); */
	term.ocx = cx;
	term.ocy = term.c.y;
	xfinishdraw();
	if (ocx != term.ocx || ocy != term.ocy)
		xximspot(term.ocx, term.ocy);
}

void
redraw(void)
{
	tfulldirt();
	draw();
}
