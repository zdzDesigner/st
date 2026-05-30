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
static int32_t tdefcolor(int *, int *, int);
static void tdeftran(char);
static void tstrsequence(uchar);

static void drawregion(int, int, int, int);

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
	int i = term.col;

	if (TLINE(y)[i - 1].mode & ATTR_WRAP)
		return i;

	while (i > 0 && TLINE(y)[i - 1].u == ' ')
		--i;

	return i;
}

int
tlinehistlen(int y)
{
	int i = term.col;

	if (TLINE_HIST(y)[i - 1].mode & ATTR_WRAP)
		return i;

	while (i > 0 && TLINE_HIST(y)[i - 1].u == ' ')
		--i;

	return i;
}

void
selstart(int col, int row, int snap)
{
	selclear();
	sel.mode = SEL_EMPTY;
	sel.type = SEL_REGULAR;
	sel.alt = IS_SET(MODE_ALTSCREEN);
	sel.snap = snap;
	sel.oe.x = sel.ob.x = col;
	sel.oe.y = sel.ob.y = row;
	selnormalize();

	if (sel.snap != 0)
		sel.mode = SEL_READY;
	tsetdirt(sel.nb.y, sel.ne.y);
}

void
selextend(int col, int row, int type, int done)
{
	int oldey, oldex, oldsby, oldsey, oldtype;

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

	if (oldey != sel.oe.y || oldex != sel.oe.x || oldtype != sel.type || sel.mode == SEL_EMPTY)
		tsetdirt(MIN(sel.nb.y, oldsby), MAX(sel.ne.y, oldsey));

	sel.mode = done ? SEL_IDLE : SEL_READY;
}

void
selnormalize(void)
{
	int i;

	if (sel.type == SEL_REGULAR && sel.ob.y != sel.oe.y) {
		sel.nb.x = sel.ob.y < sel.oe.y ? sel.ob.x : sel.oe.x;
		sel.ne.x = sel.ob.y < sel.oe.y ? sel.oe.x : sel.ob.x;
	} else {
		sel.nb.x = MIN(sel.ob.x, sel.oe.x);
		sel.ne.x = MAX(sel.ob.x, sel.oe.x);
	}
	sel.nb.y = MIN(sel.ob.y, sel.oe.y);
	sel.ne.y = MAX(sel.ob.y, sel.oe.y);

	selsnap(&sel.nb.x, &sel.nb.y, -1);
	selsnap(&sel.ne.x, &sel.ne.y, +1);

	/* expand selection over line breaks */
	if (sel.type == SEL_RECTANGULAR)
		return;
	i = tlinelen(sel.nb.y);
	if (i < sel.nb.x)
		sel.nb.x = i;
	if (tlinelen(sel.ne.y) <= sel.ne.x)
		sel.ne.x = term.col - 1;
}

int
selected(int x, int y)
{
	if (sel.mode == SEL_EMPTY || sel.ob.x == -1 ||
			sel.alt != IS_SET(MODE_ALTSCREEN))
		return 0;

	if (sel.type == SEL_RECTANGULAR)
		return BETWEEN(y, sel.nb.y, sel.ne.y)
		    && BETWEEN(x, sel.nb.x, sel.ne.x);

	return BETWEEN(y, sel.nb.y, sel.ne.y)
	    && (y != sel.nb.y || x >= sel.nb.x)
	    && (y != sel.ne.y || x <= sel.ne.x);
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
		*x = (direction < 0) ? 0 : term.col - 1;
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

	if (sel.ob.x == -1)
		return NULL;

	bufsize = (term.col+1) * (sel.ne.y-sel.nb.y+1) * UTF_SIZ;
	ptr = str = xmalloc(bufsize);

	/* append every set & selected glyph to the selection */
	for (y = sel.nb.y; y <= sel.ne.y; y++) {
		if ((linelen = tlinelen(y)) == 0) {
			*ptr++ = '\n';
			continue;
		}

		if (sel.type == SEL_RECTANGULAR) {
			gp = &TLINE(y)[sel.nb.x];
			lastx = sel.ne.x;
		} else {
			gp = &TLINE(y)[sel.nb.y == y ? sel.nb.x : 0];
			lastx = (sel.ne.y == y) ? sel.ne.x : term.col-1;
		}
		last = &TLINE(y)[MIN(lastx, linelen-1)];
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
		if ((y < sel.ne.y || lastx >= linelen) &&
		    (!(last->mode & ATTR_WRAP) || sel.type == SEL_RECTANGULAR))
			*ptr++ = '\n';
	}
	*ptr = 0;
	return str;
}

void
selclear(void)
{
	if (sel.ob.x == -1)
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

	if ((n = strlen(stty_args)) > sizeof(cmd)-1)
		die("incorrect stty parameters\n");
	memcpy(cmd, stty_args, n);
	q = cmd + n;
	siz = sizeof(cmd) - n;
	for (p = args; p && (s = *p); ++p) {
		if ((n = strlen(s)) > siz-1)
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
			next = memchr(s, '\r', n);
			DEFAULT(next, s + n);
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
			if ((r = write(cmdfd, s, (n < lim)? n : lim)) < 0)
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
	int i, j;

	for (i = 0; i < term.row-1; i++) {
		for (j = 0; j < term.col-1; j++) {
			if (term.line[i][j].mode & attr)
				return 1;
		}
	}

	return 0;
}

void
tsetdirt(int top, int bot)
{
	int i;

	LIMIT(top, 0, term.row-1);
	LIMIT(bot, 0, term.row-1);

	for (i = top; i <= bot; i++)
		term.dirty[i] = 1;
}

void
tsetdirtattr(int attr)
{
	int i, j;

	for (i = 0; i < term.row-1; i++) {
		for (j = 0; j < term.col-1; j++) {
			if (term.line[i][j].mode & attr) {
				tsetdirt(i, i);
				break;
			}
		}
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
	int alt = IS_SET(MODE_ALTSCREEN);

	if (mode == CURSOR_SAVE) {
		c[alt] = term.c;
	} else if (mode == CURSOR_LOAD) {
		term.c = c[alt];
		tmoveto(c[alt].x, c[alt].y);
	}
}

void
treset(void)
{
	uint i;

	term.c = (TCursor){{
		.mode = ATTR_NULL,
		.fg = defaultfg,
		.bg = defaultbg
	}, .x = 0, .y = 0, .state = CURSOR_DEFAULT};

	memset(term.tabs, 0, term.col * sizeof(*term.tabs));
	for (i = tabspaces; i < term.col; i += tabspaces)
		term.tabs[i] = 1;
	term.top = 0;
	term.bot = term.row - 1;
	term.mode = MODE_WRAP|MODE_UTF8;
	memset(term.trantbl, CS_USA, sizeof(term.trantbl));
	term.charset = 0;

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
	int n = a->i;

	if (n < 0)
		n = term.row + n;

	if (n > term.scr)
		n = term.scr;

	if (term.scr > 0) {
		term.scr -= n;
		selscroll(0, -n);
		tfulldirt();
	}
}

void
kscrollup(const Arg* a)
{
	int n = a->i;

	if (n < 0)
		n = term.row + n;

	if (term.scr <= HISTSIZE-n) {
		term.scr += n;
		selscroll(0, n);
		tfulldirt();
	}
}

void
tscrolldown(int orig, int n, int copyhist)
{
	int i;
	Line temp;

	LIMIT(n, 0, term.bot-orig+1);

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

	if (term.scr == 0)
		selscroll(orig, n);
}

void
tscrollup(int orig, int n, int copyhist)
{
	int i;
	Line temp;

	LIMIT(n, 0, term.bot-orig+1);

	if (copyhist) {
		term.histi = (term.histi + 1) % HISTSIZE;
		temp = term.hist[term.histi];
		term.hist[term.histi] = term.line[orig];
		term.line[orig] = temp;
	}

	if (term.scr > 0 && term.scr < HISTSIZE)
		term.scr = MIN(term.scr + n, HISTSIZE-1);

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
	if (sel.ob.x == -1)
		return;

	if (BETWEEN(sel.nb.y, orig, term.bot) != BETWEEN(sel.ne.y, orig, term.bot)) {
		selclear();
	} else if (BETWEEN(sel.nb.y, orig, term.bot)) {
		sel.ob.y += n;
		sel.oe.y += n;
		if (sel.ob.y < term.top || sel.ob.y > term.bot ||
		    sel.oe.y < term.top || sel.oe.y > term.bot) {
			selclear();
		} else {
			selnormalize();
		}
	}
}

void
tnewline(int first_col)
{
	int y = term.c.y;

	if (y == term.bot) {
		tscrollup(term.top, 1, 1);
	} else {
		y++;
	}
	tmoveto(first_col ? 0 : term.c.x, y);
}

void
csiparse(void)
{
	ZigCsiParse parsed;

	parsed = st_csiparse((const unsigned char *)csiescseq.buf, csiescseq.len);
	csiescseq.priv = parsed.priv ? 1 : 0;
	csiescseq.narg = parsed.narg;
	memcpy(csiescseq.arg, parsed.arg, sizeof(parsed.arg));
	csiescseq.mode[0] = parsed.mode[0];
	csiescseq.mode[1] = parsed.mode[1];
}

/* for absolute user moves, when decom is set */
void
tmoveato(int x, int y)
{
	tmoveto(x, y + ((term.c.state & CURSOR_ORIGIN) ? term.top: 0));
}

void
tmoveto(int x, int y)
{
	int miny, maxy;

	if (term.c.state & CURSOR_ORIGIN) {
		miny = term.top;
		maxy = term.bot;
	} else {
		miny = 0;
		maxy = term.row - 1;
	}
	term.c.state &= ~CURSOR_WRAPNEXT;
	term.c.x = LIMIT(x, 0, term.col-1);
	term.c.y = LIMIT(y, miny, maxy);
}

void
tsetchar(Rune u, Glyph *attr, int x, int y)
{
	static char *vt100_0[62] = { /* 0x41 - 0x7e */
		"↑", "↓", "→", "←", "█", "▚", "☃", /* A - G */
		0, 0, 0, 0, 0, 0, 0, 0, /* H - O */
		0, 0, 0, 0, 0, 0, 0, 0, /* P - W */
		0, 0, 0, 0, 0, 0, 0, " ", /* X - _ */
		"◆", "▒", "␉", "␌", "␍", "␊", "°", "±", /* ` - g */
		"␤", "␋", "┘", "┐", "┌", "└", "┼", "⎺", /* h - o */
		"⎻", "─", "⎼", "⎽", "├", "┤", "┴", "┬", /* p - w */
		"│", "≤", "≥", "π", "≠", "£", "·", /* x - ~ */
	};

	/*
	 * The table is proudly stolen from rxvt.
	 */
	if (term.trantbl[term.charset] == CS_GRAPHIC0 &&
	   BETWEEN(u, 0x41, 0x7e) && vt100_0[u - 0x41])
		utf8decode(vt100_0[u - 0x41], &u, UTF_SIZ);

	if (term.line[y][x].mode & ATTR_WIDE) {
		if (x+1 < term.col) {
			term.line[y][x+1].u = ' ';
			term.line[y][x+1].mode &= ~ATTR_WDUMMY;
		}
	} else if (term.line[y][x].mode & ATTR_WDUMMY) {
		term.line[y][x-1].u = ' ';
		term.line[y][x-1].mode &= ~ATTR_WIDE;
	}

	term.dirty[y] = 1;
	term.line[y][x] = *attr;
	term.line[y][x].u = u;

	if (isboxdraw(u))
		term.line[y][x].mode |= ATTR_BOXDRAW;
}

void
tclearregion(int x1, int y1, int x2, int y2)
{
	int x, y, temp;
	Glyph *gp;

	if (x1 > x2)
		temp = x1, x1 = x2, x2 = temp;
	if (y1 > y2)
		temp = y1, y1 = y2, y2 = temp;

	LIMIT(x1, 0, term.maxcol-1);
	LIMIT(x2, 0, term.maxcol-1);
	LIMIT(y1, 0, term.row-1);
	LIMIT(y2, 0, term.row-1);

	for (y = y1; y <= y2; y++) {
		term.dirty[y] = 1;
		for (x = x1; x <= x2; x++) {
			gp = &term.line[y][x];
			if (selected(x, y))
				selclear();
			gp->fg = term.c.attr.fg;
			gp->bg = term.c.attr.bg;
			gp->mode = 0;
			gp->u = ' ';
		}
	}
}

void
tdeletechar(int n)
{
	int dst, src, size;
	Glyph *line;

	LIMIT(n, 0, term.col - term.c.x);

	dst = term.c.x;
	src = term.c.x + n;
	size = term.col - src;
	line = term.line[term.c.y];

	memmove(&line[dst], &line[src], size * sizeof(Glyph));
	tclearregion(term.col-n, term.c.y, term.col-1, term.c.y);
}

void
tinsertblank(int n)
{
	int dst, src, size;
	Glyph *line;

	LIMIT(n, 0, term.col - term.c.x);

	dst = term.c.x + n;
	src = term.c.x;
	size = term.col - dst;
	line = term.line[term.c.y];

	memmove(&line[dst], &line[src], size * sizeof(Glyph));
	tclearregion(src, term.c.y, dst - 1, term.c.y);
}

void
tinsertblankline(int n)
{
	if (BETWEEN(term.c.y, term.top, term.bot))
		tscrolldown(term.c.y, n, 0);
}

void
tdeleteline(int n)
{
	if (BETWEEN(term.c.y, term.top, term.bot))
		tscrollup(term.c.y, n, 0);
}

int32_t
tdefcolor(int *attr, int *npar, int l)
{
	ZigColorParse parsed;
	int oldnpar = *npar;

	parsed = st_tdefcolor(attr, *npar, l);
	*npar = parsed.next_npar;

	switch (parsed.kind) {
	case ST_ZIG_COLOR_OK:
		return parsed.idx;
	case ST_ZIG_COLOR_BAD_COUNT:
		fprintf(stderr,
			"erresc(38): Incorrect number of parameters (%d)\n",
			oldnpar);
		break;
	case ST_ZIG_COLOR_BAD_RGB:
		fprintf(stderr, "erresc: bad rgb color (%u,%u,%u)\n",
			parsed.r, parsed.g, parsed.b);
		break;
	case ST_ZIG_COLOR_BAD_INDEX:
		fprintf(stderr, "erresc: bad fgcolor %d\n", parsed.value);
		break;
	case ST_ZIG_COLOR_UNKNOWN:
	default:
		fprintf(stderr,
		        "erresc(38): gfx attr %d unknown\n", parsed.value);
		break;
	}

	return -1;
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
	int temp;

	LIMIT(t, 0, term.row-1);
	LIMIT(b, 0, term.row-1);
	if (t > b) {
		temp = t;
		t = b;
		b = temp;
	}
	term.top = t;
	term.bot = b;
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
	int alt, *lim;

	for (lim = args + narg; args < lim; ++args) {
		if (priv) {
			switch (*args) {
			case 1: /* DECCKM -- Cursor key */
				xsetmode(set, MODE_APPCURSOR);
				break;
			case 5: /* DECSCNM -- Reverse video */
				xsetmode(set, MODE_REVERSE);
				break;
			case 6: /* DECOM -- Origin */
				MODBIT(term.c.state, set, CURSOR_ORIGIN);
				tmoveato(0, 0);
				break;
			case 7: /* DECAWM -- Auto wrap */
				MODBIT(term.mode, set, MODE_WRAP);
				break;
			case 0:  /* Error (IGNORED) */
			case 2:  /* DECANM -- ANSI/VT52 (IGNORED) */
			case 3:  /* DECCOLM -- Column  (IGNORED) */
			case 4:  /* DECSCLM -- Scroll (IGNORED) */
			case 8:  /* DECARM -- Auto repeat (IGNORED) */
			case 18: /* DECPFF -- Printer feed (IGNORED) */
			case 19: /* DECPEX -- Printer extent (IGNORED) */
			case 42: /* DECNRCM -- National characters (IGNORED) */
			case 12: /* att610 -- Start blinking cursor (IGNORED) */
				break;
			case 25: /* DECTCEM -- Text Cursor Enable Mode */
				xsetmode(!set, MODE_HIDE);
				break;
			case 9:    /* X10 mouse compatibility mode */
				xsetpointermotion(0);
				xsetmode(0, MODE_MOUSE);
				xsetmode(set, MODE_MOUSEX10);
				break;
			case 1000: /* 1000: report button press */
				xsetpointermotion(0);
				xsetmode(0, MODE_MOUSE);
				xsetmode(set, MODE_MOUSEBTN);
				break;
			case 1002: /* 1002: report motion on button press */
				xsetpointermotion(0);
				xsetmode(0, MODE_MOUSE);
				xsetmode(set, MODE_MOUSEMOTION);
				break;
			case 1003: /* 1003: enable all mouse motions */
				xsetpointermotion(set);
				xsetmode(0, MODE_MOUSE);
				xsetmode(set, MODE_MOUSEMANY);
				break;
			case 1004: /* 1004: send focus events to tty */
				xsetmode(set, MODE_FOCUS);
				break;
			case 1006: /* 1006: extended reporting mode */
				xsetmode(set, MODE_MOUSESGR);
				break;
			case 1034:
				xsetmode(set, MODE_8BIT);
				break;
			case 1049: /* swap screen & set/restore cursor as xterm */
				if (!allowaltscreen)
					break;
				tcursor((set) ? CURSOR_SAVE : CURSOR_LOAD);
				/* FALLTHROUGH */
			case 47: /* swap screen */
			case 1047:
				if (!allowaltscreen)
					break;
				alt = IS_SET(MODE_ALTSCREEN);
				if (alt) {
					tclearregion(0, 0, term.col-1,
							term.row-1);
				}
				if (set ^ alt) /* set is always 1 or 0 */
					tswapscreen();
				if (*args != 1049)
					break;
				/* FALLTHROUGH */
			case 1048:
				tcursor((set) ? CURSOR_SAVE : CURSOR_LOAD);
				break;
			case 2004: /* 2004: bracketed paste mode */
				xsetmode(set, MODE_BRCKTPASTE);
				break;
			/* Not implemented mouse modes. See comments there. */
			case 1001: /* mouse highlight mode; can hang the
				      terminal by design when implemented. */
			case 1005: /* UTF-8 mouse mode; will confuse
				      applications not supporting UTF-8
				      and luit. */
			case 1015: /* urxvt mangled mouse mode; incompatible
				      and can be mistaken for other control
				      codes. */
				break;
			default:
				fprintf(stderr,
					"erresc: unknown private set/reset mode %d\n",
					*args);
				break;
			}
		} else {
			switch (*args) {
			case 0:  /* Error (IGNORED) */
				break;
			case 2:
				xsetmode(set, MODE_KBDLOCK);
				break;
			case 4:  /* IRM -- Insertion-replacement */
				MODBIT(term.mode, set, MODE_INSERT);
				break;
			case 12: /* SRM -- Send/Receive */
				MODBIT(term.mode, !set, MODE_ECHO);
				break;
			case 20: /* LNM -- Linefeed/new line */
				MODBIT(term.mode, set, MODE_CRLF);
				break;
			default:
				fprintf(stderr,
					"erresc: unknown set/reset mode %d\n",
					*args);
				break;
			}
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
		edit = st_planedit('@', csiescseq.arg, csiescseq.narg,
			term.c.x, term.c.y);
		tapplyedit(&edit);
		break;
	case 'A': /* CUU -- Cursor <n> Up */
		cursor = st_plancursor('A', term.c.x, term.c.y,
			csiescseq.arg, csiescseq.narg);
		tapplycursor(&cursor);
		break;
	case 'B': /* CUD -- Cursor <n> Down */
	case 'e': /* VPR --Cursor <n> Down */
		cursor = st_plancursor(csiescseq.mode[0], term.c.x, term.c.y,
			csiescseq.arg, csiescseq.narg);
		tapplycursor(&cursor);
		break;
	case 'i': /* MC -- Media Copy */
		misc = st_planmisc('i', 0, csiescseq.arg, csiescseq.narg);
		tapplymisc(&misc);
		break;
	case 'c': /* DA -- Device Attributes */
		light = st_planlight('c', csiescseq.arg, csiescseq.narg,
			term.c.x, term.c.y);
		tapplylight(&light, buf, &len);
		break;
	case 'b': /* REP -- if last char is printable print it <n> more times */
		misc = st_planmisc('b', 0, csiescseq.arg, csiescseq.narg);
		tapplymisc(&misc);
		break;
	case 'C': /* CUF -- Cursor <n> Forward */
	case 'a': /* HPR -- Cursor <n> Forward */
		cursor = st_plancursor(csiescseq.mode[0], term.c.x, term.c.y,
			csiescseq.arg, csiescseq.narg);
		tapplycursor(&cursor);
		break;
	case 'D': /* CUB -- Cursor <n> Backward */
		cursor = st_plancursor('D', term.c.x, term.c.y,
			csiescseq.arg, csiescseq.narg);
		tapplycursor(&cursor);
		break;
	case 'E': /* CNL -- Cursor <n> Down and first col */
		cursor = st_plancursor('E', term.c.x, term.c.y,
			csiescseq.arg, csiescseq.narg);
		tapplycursor(&cursor);
		break;
	case 'F': /* CPL -- Cursor <n> Up and first col */
		cursor = st_plancursor('F', term.c.x, term.c.y,
			csiescseq.arg, csiescseq.narg);
		tapplycursor(&cursor);
		break;
	case 'g': /* TBC -- Tabulation clear */
		light = st_planlight('g', csiescseq.arg, csiescseq.narg,
			term.c.x, term.c.y);
		if (light.kind == ST_ZIG_LIGHT_UNKNOWN)
			goto unknown;
		tapplylight(&light, buf, &len);
		break;
	case 'G': /* CHA -- Move to <col> */
	case '`': /* HPA */
		cursor = st_plancursor(csiescseq.mode[0], term.c.x, term.c.y,
			csiescseq.arg, csiescseq.narg);
		tapplycursor(&cursor);
		break;
	case 'H': /* CUP -- Move to <row> <col> */
	case 'f': /* HVP */
		cursor = st_plancursor(csiescseq.mode[0], term.c.x, term.c.y,
			csiescseq.arg, csiescseq.narg);
		tapplycursor(&cursor);
		break;
	case 'I': /* CHT -- Cursor Forward Tabulation <n> tab stops */
		light = st_planlight('I', csiescseq.arg, csiescseq.narg,
			term.c.x, term.c.y);
		tapplylight(&light, buf, &len);
		break;
	case 'J': /* ED -- Clear screen */
		erase = st_planerase('J', csiescseq.arg[0], term.c.x, term.c.y,
			term.col, term.row);
		if (erase.kind != ST_ZIG_ERASE_OK)
			goto unknown;
		tapplyerase(&erase);
		break;
	case 'K': /* EL -- Clear line */
		erase = st_planerase('K', csiescseq.arg[0], term.c.x, term.c.y,
			term.col, term.row);
		if (erase.kind != ST_ZIG_ERASE_OK)
			goto unknown;
		tapplyerase(&erase);
		break;
	case 'S': /* SU -- Scroll <n> line up */
		edit = st_planedit('S', csiescseq.arg, csiescseq.narg,
			term.c.x, term.c.y);
		tapplyedit(&edit);
		break;
	case 'T': /* SD -- Scroll <n> line down */
		edit = st_planedit('T', csiescseq.arg, csiescseq.narg,
			term.c.x, term.c.y);
		tapplyedit(&edit);
		break;
	case 'L': /* IL -- Insert <n> blank lines */
		edit = st_planedit('L', csiescseq.arg, csiescseq.narg,
			term.c.x, term.c.y);
		tapplyedit(&edit);
		break;
	case 'l': /* RM -- Reset Mode */
		tsetmode(csiescseq.priv, 0, csiescseq.arg, csiescseq.narg);
		break;
	case 'M': /* DL -- Delete <n> lines */
		edit = st_planedit('M', csiescseq.arg, csiescseq.narg,
			term.c.x, term.c.y);
		tapplyedit(&edit);
		break;
	case 'X': /* ECH -- Erase <n> char */
		edit = st_planedit('X', csiescseq.arg, csiescseq.narg,
			term.c.x, term.c.y);
		tapplyedit(&edit);
		break;
	case 'P': /* DCH -- Delete <n> char */
		edit = st_planedit('P', csiescseq.arg, csiescseq.narg,
			term.c.x, term.c.y);
		tapplyedit(&edit);
		break;
	case 'Z': /* CBT -- Cursor Backward Tabulation <n> tab stops */
		light = st_planlight('Z', csiescseq.arg, csiescseq.narg,
			term.c.x, term.c.y);
		tapplylight(&light, buf, &len);
		break;
	case 'd': /* VPA -- Move to <row> */
		cursor = st_plancursor('d', term.c.x, term.c.y,
			csiescseq.arg, csiescseq.narg);
		tapplycursor(&cursor);
		break;
	case 'h': /* SM -- Set terminal mode */
		tsetmode(csiescseq.priv, 1, csiescseq.arg, csiescseq.narg);
		break;
	case 'm': /* SGR -- Terminal attribute (color) */
		tsetattr(csiescseq.arg, csiescseq.narg);
		break;
	case 'n': /* DSR – Device Status Report (cursor position) */
		light = st_planlight('n', csiescseq.arg, csiescseq.narg,
			term.c.x, term.c.y);
		tapplylight(&light, buf, &len);
		break;
	case 'r': /* DECSTBM -- Set Scrolling Region */
		state = st_planstate('r', csiescseq.priv, csiescseq.arg,
			csiescseq.narg, term.row);
		if (state.kind == ST_ZIG_STATE_UNKNOWN) {
			goto unknown;
		}
		tapplystate(&state);
		break;
	case 's': /* DECSC -- Save cursor position (ANSI.SYS) */
		state = st_planstate('s', csiescseq.priv, csiescseq.arg,
			csiescseq.narg, term.row);
		tapplystate(&state);
		break;
	case 'u': /* DECRC -- Restore cursor position (ANSI.SYS) */
		state = st_planstate('u', csiescseq.priv, csiescseq.arg,
			csiescseq.narg, term.row);
		tapplystate(&state);
		break;
	case ' ':
		misc = st_planmisc(' ', csiescseq.mode[1], csiescseq.arg,
			csiescseq.narg);
		if (misc.kind == ST_ZIG_MISC_UNKNOWN)
			goto unknown;
		if (misc.kind == ST_ZIG_MISC_SET_CURSOR_STYLE && xsetcursor(misc.value))
			goto unknown;
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
	char *p = NULL, *dec;
	int j, narg, par;

	term.esc &= ~(ESC_STR_END|ESC_STR);
	strparse();
	par = (narg = strescseq.narg) ? atoi(strescseq.args[0]) : 0;

	switch (strescseq.type) {
	case ']': /* OSC -- Operating System Command */
		switch (par) {
		case 0:
			if (narg > 1) {
				xsettitle(strescseq.args[1]);
				xseticontitle(strescseq.args[1]);
			}
			return;
		case 1:
			if (narg > 1)
				xseticontitle(strescseq.args[1]);
			return;
		case 2:
			if (narg > 1)
				xsettitle(strescseq.args[1]);
			return;
		case 52:
			if (narg > 2 && allowwindowops) {
				dec = base64dec(strescseq.args[2]);
				if (dec) {
					xsetsel(dec);
					xclipcopy();
				} else {
					fprintf(stderr, "erresc: invalid base64\n");
				}
			}
			return;
		case 4: /* color set */
			if (narg < 3)
				break;
			p = strescseq.args[2];
			/* FALLTHROUGH */
		case 104: /* color reset, here p = NULL */
			j = (narg > 1) ? atoi(strescseq.args[1]) : -1;
			if (xsetcolorname(j, p)) {
				if (par == 104 && narg <= 1)
					return; /* color reset without parameter */
				fprintf(stderr, "erresc: invalid color j=%d, p=%s\n",
				        j, p ? p : "(null)");
			} else {
				/*
				 * TODO if defaultbg color is changed, borders
				 * are dirty
				 */
				redraw();
			}
			return;
		}
		break;
	case 'k': /* old title set compatibility */
		xsettitle(strescseq.args[0]);
		return;
	case 'P': /* DCS -- Device Control String */
	case '_': /* APC -- Application Program Command */
	case '^': /* PM -- Privacy Message */
		return;
	}

	fprintf(stderr, "erresc: unknown str ");
	strdump();
}

void
strparse(void)
{
	int c;
	char *p = strescseq.buf;

	strescseq.narg = 0;
	strescseq.buf[strescseq.len] = '\0';

	if (*p == '\0')
		return;

	while (strescseq.narg < STR_ARG_SIZ) {
		strescseq.args[strescseq.narg++] = p;
		while ((c = *p) != ';' && c != '\0')
			++p;
		if (c == '\0')
			return;
		*p++ = '\0';
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
		lastpos = MIN(tlinehistlen(n) + 1, term.col) - 1;
		if (lastpos < 0)
			break;
        if (lastpos == 0)
            continue;
		end = &bp[lastpos + 1];
		for (; bp < end; ++bp)
			if (xwrite(to[1], buf, utf8encode(bp->u, buf)) < 0)
				break;
		if ((newline = TLINE_HIST(n)[lastpos].mode & ATTR_WRAP))
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

	bp = &term.line[n][0];
	end = &bp[MIN(tlinelen(n), term.col) - 1];
	if (bp != end || bp->u != ' ') {
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
	uint x = term.c.x;

	if (n > 0) {
		while (x < term.col && n--)
			for (++x; x < term.col && !term.tabs[x]; ++x)
				/* nothing */ ;
	} else if (n < 0) {
		while (x > 0 && n++)
			for (--x; x > 0 && !term.tabs[x]; --x)
				/* nothing */ ;
	}
	term.c.x = LIMIT(x, 0, term.col-1);
}

void
tdefutf8(char ascii)
{
	if (ascii == 'G')
		term.mode |= MODE_UTF8;
	else if (ascii == '@')
		term.mode &= ~MODE_UTF8;
}

void
tdeftran(char ascii)
{
	static char cs[] = "0B";
	static int vcs[] = {CS_GRAPHIC0, CS_USA};
	char *p;

	if ((p = strchr(cs, ascii)) == NULL) {
		fprintf(stderr, "esc unhandled charset: ESC ( %c\n", ascii);
	} else {
		term.trantbl[term.icharset] = vcs[p - cs];
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
	switch (c) {
	case 0x90:   /* DCS -- Device Control String */
		c = 'P';
		break;
	case 0x9f:   /* APC -- Application Program Command */
		c = '_';
		break;
	case 0x9e:   /* PM -- Privacy Message */
		c = '^';
		break;
	case 0x9d:   /* OSC -- Operating System Command */
		c = ']';
		break;
	}
	strreset();
	strescseq.type = c;
	term.esc |= ESC_STR;
}

void
tcontrolcode(uchar ascii)
{
	switch (ascii) {
	case '\t':   /* HT */
		tputtab(1);
		return;
	case '\b':   /* BS */
		tmoveto(term.c.x-1, term.c.y);
		return;
	case '\r':   /* CR */
		tmoveto(0, term.c.y);
		return;
	case '\f':   /* LF */
	case '\v':   /* VT */
	case '\n':   /* LF */
		/* go to first col if the mode is set */
		tnewline(IS_SET(MODE_CRLF));
		return;
	case '\a':   /* BEL */
		if (term.esc & ESC_STR_END) {
			/* backwards compatibility to xterm */
			strhandle();
		} else {
			xbell();
		}
		break;
	case '\033': /* ESC */
		csireset();
		term.esc &= ~(ESC_CSI|ESC_ALTCHARSET|ESC_TEST);
		term.esc |= ESC_START;
		return;
	case '\016': /* SO (LS1 -- Locking shift 1) */
	case '\017': /* SI (LS0 -- Locking shift 0) */
		term.charset = 1 - (ascii - '\016');
		return;
	case '\032': /* SUB */
		tsetchar('?', &term.c.attr, term.c.x, term.c.y);
		/* FALLTHROUGH */
	case '\030': /* CAN */
		csireset();
		break;
	case '\005': /* ENQ (IGNORED) */
	case '\000': /* NUL (IGNORED) */
	case '\021': /* XON (IGNORED) */
	case '\023': /* XOFF (IGNORED) */
	case 0177:   /* DEL (IGNORED) */
		return;
	case 0x80:   /* TODO: PAD */
	case 0x81:   /* TODO: HOP */
	case 0x82:   /* TODO: BPH */
	case 0x83:   /* TODO: NBH */
	case 0x84:   /* TODO: IND */
		break;
	case 0x85:   /* NEL -- Next line */
		tnewline(1); /* always go to first col */
		break;
	case 0x86:   /* TODO: SSA */
	case 0x87:   /* TODO: ESA */
		break;
	case 0x88:   /* HTS -- Horizontal tab stop */
		term.tabs[term.c.x] = 1;
		break;
	case 0x89:   /* TODO: HTJ */
	case 0x8a:   /* TODO: VTS */
	case 0x8b:   /* TODO: PLD */
	case 0x8c:   /* TODO: PLU */
	case 0x8d:   /* TODO: RI */
	case 0x8e:   /* TODO: SS2 */
	case 0x8f:   /* TODO: SS3 */
	case 0x91:   /* TODO: PU1 */
	case 0x92:   /* TODO: PU2 */
	case 0x93:   /* TODO: STS */
	case 0x94:   /* TODO: CCH */
	case 0x95:   /* TODO: MW */
	case 0x96:   /* TODO: SPA */
	case 0x97:   /* TODO: EPA */
	case 0x98:   /* TODO: SOS */
	case 0x99:   /* TODO: SGCI */
		break;
	case 0x9a:   /* DECID -- Identify Terminal */
		ttywrite(vtiden, strlen(vtiden), 0);
		break;
	case 0x9b:   /* TODO: CSI */
	case 0x9c:   /* TODO: ST */
		break;
	case 0x90:   /* DCS -- Device Control String */
	case 0x9d:   /* OSC -- Operating System Command */
	case 0x9e:   /* PM -- Privacy Message */
	case 0x9f:   /* APC -- Application Program Command */
		tstrsequence(ascii);
		return;
	}
	/* only CAN, SUB, \a and C1 chars interrupt a sequence */
	term.esc &= ~(ESC_STR_END|ESC_STR);
}

/*
 * returns 1 when the sequence is finished and it hasn't to read
 * more characters for this sequence, otherwise 0
 */
int
eschandle(uchar ascii)
{
	switch (ascii) {
	case '[':
		term.esc |= ESC_CSI;
		return 0;
	case '#':
		term.esc |= ESC_TEST;
		return 0;
	case '%':
		term.esc |= ESC_UTF8;
		return 0;
	case 'P': /* DCS -- Device Control String */
	case '_': /* APC -- Application Program Command */
	case '^': /* PM -- Privacy Message */
	case ']': /* OSC -- Operating System Command */
	case 'k': /* old title set compatibility */
		tstrsequence(ascii);
		return 0;
	case 'n': /* LS2 -- Locking shift 2 */
	case 'o': /* LS3 -- Locking shift 3 */
		term.charset = 2 + (ascii - 'n');
		break;
	case '(': /* GZD4 -- set primary charset G0 */
	case ')': /* G1D4 -- set secondary charset G1 */
	case '*': /* G2D4 -- set tertiary charset G2 */
	case '+': /* G3D4 -- set quaternary charset G3 */
		term.icharset = ascii - '(';
		term.esc |= ESC_ALTCHARSET;
		return 0;
	case 'D': /* IND -- Linefeed */
		if (term.c.y == term.bot) {
			tscrollup(term.top, 1, 1);
		} else {
			tmoveto(term.c.x, term.c.y+1);
		}
		break;
	case 'E': /* NEL -- Next line */
		tnewline(1); /* always go to first col */
		break;
	case 'H': /* HTS -- Horizontal tab stop */
		term.tabs[term.c.x] = 1;
		break;
	case 'M': /* RI -- Reverse index */
		if (term.c.y == term.top) {
			tscrolldown(term.top, 1, 1);
		} else {
			tmoveto(term.c.x, term.c.y-1);
		}
		break;
	case 'Z': /* DECID -- Identify Terminal */
		ttywrite(vtiden, strlen(vtiden), 0);
		break;
	case 'c': /* RIS -- Reset to initial state */
		treset();
		resettitle();
		xloadcols();
		break;
	case '=': /* DECPAM -- Application keypad */
		xsetmode(1, MODE_APPKEYPAD);
		break;
	case '>': /* DECPNM -- Normal keypad */
		xsetmode(0, MODE_APPKEYPAD);
		break;
	case '7': /* DECSC -- Save Cursor */
		tcursor(CURSOR_SAVE);
		break;
	case '8': /* DECRC -- Restore Cursor */
		tcursor(CURSOR_LOAD);
		break;
	case '\\': /* ST -- String Terminator */
		if (term.esc & ESC_STR_END)
			strhandle();
		break;
	default:
		fprintf(stderr, "erresc: unknown sequence ESC 0x%02X '%c'\n",
			(uchar) ascii, isprint(ascii)? ascii:'.');
		break;
	}
	return 1;
}

void
tputc(Rune u)
{
	char c[UTF_SIZ];
	int control;
	int width, len;
	Glyph *gp;

	control = ISCONTROL(u);
	if (u < 127 || !IS_SET(MODE_UTF8)) {
		c[0] = u;
		width = len = 1;
	} else {
		len = utf8encode(u, c);
		if (!control && (width = wcwidth(u)) == -1)
			width = 1;
	}

	if (IS_SET(MODE_PRINT))
		tprinter(c, len);

	/*
	 * STR sequence must be checked before anything else
	 * because it uses all following characters until it
	 * receives a ESC, a SUB, a ST or any other C1 control
	 * character.
	 */
	if (term.esc & ESC_STR) {
		if (u == '\a' || u == 030 || u == 032 || u == 033 ||
		   ISCONTROLC1(u)) {
			term.esc &= ~(ESC_START|ESC_STR);
			term.esc |= ESC_STR_END;
			goto check_control_code;
		}

		if (strescseq.len+len >= strescseq.siz) {
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
			if (strescseq.siz > (SIZE_MAX - UTF_SIZ) / 2)
				return;
			strescseq.siz *= 2;
			strescseq.buf = xrealloc(strescseq.buf, strescseq.siz);
		}

		memmove(&strescseq.buf[strescseq.len], c, len);
		strescseq.len += len;
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
		if (!term.esc)
			term.lastc = 0;
		return;
	} else if (term.esc & ESC_START) {
		if (term.esc & ESC_CSI) {
			csiescseq.buf[csiescseq.len++] = u;
			if (BETWEEN(u, 0x40, 0x7E)
					|| csiescseq.len >= \
					sizeof(csiescseq.buf)-1) {
				term.esc = 0;
				csiparse();
				csihandle();
			}
			return;
		} else if (term.esc & ESC_UTF8) {
			tdefutf8(u);
		} else if (term.esc & ESC_ALTCHARSET) {
			tdeftran(u);
		} else if (term.esc & ESC_TEST) {
			tdectest(u);
		} else {
			if (!eschandle(u))
				return;
			/* sequence already finished */
		}
		term.esc = 0;
		/*
		 * All characters which form part of a sequence are not
		 * printed
		 */
		return;
	}
	if (selected(term.c.x, term.c.y))
		selclear();

	gp = &term.line[term.c.y][term.c.x];
	if (IS_SET(MODE_WRAP) && (term.c.state & CURSOR_WRAPNEXT)) {
		gp->mode |= ATTR_WRAP;
		tnewline(1);
		gp = &term.line[term.c.y][term.c.x];
	}

	if (IS_SET(MODE_INSERT) && term.c.x+width < term.col)
		memmove(gp+width, gp, (term.col - term.c.x - width) * sizeof(Glyph));

	if (term.c.x+width > term.col) {
		tnewline(1);
		gp = &term.line[term.c.y][term.c.x];
	}

	tsetchar(u, &term.c.attr, term.c.x, term.c.y);
	term.lastc = u;

	if (width == 2) {
		gp->mode |= ATTR_WIDE;
		if (term.c.x+1 < term.col) {
			gp[1].u = '\0';
			gp[1].mode = ATTR_WDUMMY;
		}
	}
	if (term.c.x+width < term.col) {
		tmoveto(term.c.x+width, term.c.y);
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
		if (show_ctrl && ISCONTROL(u)) {
			if (u & 0x80) {
				u &= 0x7f;
				tputc('^');
				tputc('[');
			} else if (u != '\n' && u != '\r' && u != '\t') {
				u ^= 0x40;
				tputc('^');
			}
		}
		tputc(u);
	}
	return n;
}

void
tresize(int col, int row)
{
	int i, j;
	int tmp;
	int minrow, mincol;
	int *bp;
	TCursor c;

	tmp = col;
	if (!term.maxcol)
		term.maxcol = term.col;
	col = MAX(col, term.maxcol);
	minrow = MIN(row, term.row);
	mincol = MIN(col, term.maxcol);

	if (col < 1 || row < 1) {
		fprintf(stderr,
		        "tresize: error resizing to %dx%d\n", col, row);
		return;
	}

	/*
	 * slide screen to keep cursor where we expect it -
	 * tscrollup would work here, but we can optimize to
	 * memmove because we're freeing the earlier lines
	 */
	for (i = 0; i <= term.c.y - row; i++) {
		free(term.line[i]);
		free(term.alt[i]);
	}
	/* ensure that both src and dst are not NULL */
	if (i > 0) {
		memmove(term.line, term.line + i, row * sizeof(Line));
		memmove(term.alt, term.alt + i, row * sizeof(Line));
	}
	for (i += row; i < term.row; i++) {
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
	for (i = 0; i < minrow; i++) {
		term.line[i] = xrealloc(term.line[i], col * sizeof(Glyph));
		term.alt[i]  = xrealloc(term.alt[i],  col * sizeof(Glyph));
	}

	/* allocate any new rows */
	for (/* i = minrow */; i < row; i++) {
		term.line[i] = xmalloc(col * sizeof(Glyph));
		term.alt[i] = xmalloc(col * sizeof(Glyph));
	}
	if (col > term.maxcol) {
		bp = term.tabs + term.maxcol;

		memset(bp, 0, sizeof(*term.tabs) * (col - term.maxcol));
		while (--bp > term.tabs && !*bp)
			/* nothing */ ;
		for (bp += tabspaces; bp < term.tabs + col; bp += tabspaces)
			*bp = 1;
	}
	/* update terminal size */
	term.col = tmp;
	term.maxcol = col;
	term.row = row;
	/* reset scrolling region */
	tsetscroll(0, row-1);
	/* make use of the LIMIT in tmoveto */
	tmoveto(term.c.x, term.c.y);
	/* Clearing both screens (it makes dirty all lines) */
	c = term.c;
	for (i = 0; i < 2; i++) {
		if (mincol < col && 0 < minrow) {
			tclearregion(mincol, 0, col - 1, minrow - 1);
		}
		if (0 < col && minrow < row) {
			tclearregion(0, minrow, col - 1, row - 1);
		}
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
		if (!term.dirty[y])
			continue;

		term.dirty[y] = 0;
		xdrawline(TLINE(y), x1, y, x2);
	}
}

void
draw(void)
{
	int cx = term.c.x, ocx = term.ocx, ocy = term.ocy;

	if (!xstartdraw())
		return;

	/* adjust cursor position */
	LIMIT(term.ocx, 0, term.col-1);
	LIMIT(term.ocy, 0, term.row-1);
	if (term.line[term.ocy][term.ocx].mode & ATTR_WDUMMY)
		term.ocx--;
	if (term.line[term.c.y][cx].mode & ATTR_WDUMMY)
		cx--;

	drawregion(0, 0, term.col, term.row);
	if (term.scr == 0)
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
