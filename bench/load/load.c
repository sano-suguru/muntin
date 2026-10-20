/* The load client of scripts/bench_load.sh: a closed-loop or open-loop
 * HTTP/1.1 keep-alive or prior-knowledge h2c load generator that checks
 * every response it reads. Not part of Muntin and not run by CI; Linux only
 * (epoll). bench/load/test_load.py checks that it counts what a broken
 * server sends.
 *
 *   load --port P --proto h1|h2c --conns C [--streams S] [--threads T]
 *        --warmup W_S --duration D_S [--timeout MS] [--linger MS] --method M
 *        --path PATH [--body FILE]
 *        (--expect FILE | --expect-text TEXT | --expect-fields)
 *        [--headers none|browser] [--require-header 'name: value']
 *        [--content-type TYPE] [--slow-path PATH --slow-every N]
 *        [--pid PID] [--term-at MS] [--rate R]
 *
 * C connections to 127.0.0.1:P each keep one request in flight (h1) or S
 * streams (h2c), from T threads. Every request is METHOD PATH with BODY;
 * with --slow-every N, every Nth request a thread sends is `GET SLOW_PATH`
 * instead, whose answer must be `slow`. A request with a body says
 * Content-Type TYPE (default application/octet-stream). --headers browser
 * adds the fields of a browser's navigation (BROWSER below) to every
 * request. --expect-fields expects the answer bench/load's servers give to
 * `GET /headers`: the request's fields as the handler sees them
 * (fields_echo below). Requests sent during the first W_S seconds are
 * warm-up; those sent in the D_S seconds after (the window) are measured;
 * after that none is sent, the run waits for the ones in flight, then
 * lingers --linger MS (default 300) with none in flight, still reading and
 * checking what the server sends. With --term-at MS the client sends
 * SIGTERM to PID MS milliseconds into the window and goes on sending:
 * requests sent from then on are counted apart (`after_`).
 *
 * Closed loop, the default: each connection (h1) or stream (h2c) sends its
 * next request as soon as the last one ended, so a slower server is sent
 * fewer, and a request is due when it is sent. Open loop, with --rate R:
 * requests are due every 1/R seconds from the start, whatever the answers
 * (each thread takes every T-th), and each is sent when it is due on a free
 * connection or stream; the C connections or C*S streams are the most in
 * flight. One due with none free waits (`queued`) and goes first when one
 * frees, if that is before the window's end; one due in the window and not
 * sent by its end is `unsent`, not a request. Warm-up, window and SIGTERM
 * split requests by due time: one due in the window is measured whenever
 * it was sent. Either way a request's latency counts from when it was due,
 * so in open loop it includes the wait for a free connection (no
 * coordinated omission).
 *
 * Each request sent (this client began to write it) ends in exactly one
 * outcome:
 * - ok: a whole response, well formed (below), status 200, the body
 *   exactly the expected bytes, and the required header present;
 * - status: a whole well-formed response with another status;
 * - invalid: a response that began to arrive but is not whole or not well
 *   formed, or a 200 whose body or headers are not the expected ones; also
 *   every stream in flight on an h2c connection that broke the protocol;
 * - disconnected: no byte of its response arrived before its connection
 *   closed or reset, or before the server reset or refused (GOAWAY) its
 *   stream;
 * - timeout: no whole response within --timeout (default 10000) ms of its
 *   sending; the client then closes the connection (h1) or resets the
 *   stream (h2c).
 * Well formed over HTTP/1.1: a status line `HTTP/1.1 NNN reason` (the SP
 * before the reason even when it is empty); field lines with a token name,
 * no whitespace before the colon, no obs-fold, no CR or LF but each line's
 * CRLF; no control character but HTAB in a value or the reason (RFC 9110
 * field-value); no Transfer-Encoding; one Content-Length value (repeated
 * identically at most) and exactly that many body bytes; no byte after it
 * before the next request. A `close` among Connection's tokens ends the
 * connection after that answer. Over h2c: a SETTINGS frame first (the
 * server's preface), with SETTINGS_ENABLE_PUSH 0 if any; frames within
 * the default 16,384-byte frame size; on stream ids this client opened,
 * but PRIORITY, which may name an idle one (not stream 0, 5 bytes, not
 * depending on its own stream); HPACK without Huffman coding (it is not
 * decoded, so it counts as invalid with that reason); one
 * `:status` first and no other pseudo-header; lowercase token names, no
 * connection-specific field, values without a control character but HTAB
 * and without surrounding whitespace; Content-Length, if any, equal to the
 * DATA received; no PUSH_PROMISE, no trailers; DATA within this client's
 * flow-control windows; WINDOW_UPDATE increments above 0 that keep the
 * server's windows within 2^31-1 (a stream error makes only that stream
 * invalid and resets it); and no DATA or HEADERS on a stream after the
 * server ended it (END_STREAM, RST_STREAM, or GOAWAY refusing it). That
 * last one cannot change the outcome already counted for that stream: it
 * is counted as `after_end`. Frames on a stream this client reset are
 * ignored, as RFC 9113 section 5.1 allows.
 * Over h2c, `conn_errors` counts connection errors (RFC 9113 5.4.1): a
 * rule above broken for the connection as a whole (the preface, SETTINGS,
 * frame size, a frame on an idle stream, HPACK decoding, PUSH_PROMISE, the
 * connection's window or its WINDOW_UPDATE, an `after_end` frame, a stream
 * error on a stream not in flight) and a frame or header block cut short
 * by the connection's end. It counts them whether or not a request was in
 * flight, since an error after the last answer leaves no request to count
 * it on. The connection is then closed and the streams in flight on it
 * are invalid; one whose frame header arrived before the cut is invalid,
 * not disconnected. A malformed response head or body, a stream's own
 * window or WINDOW_UPDATE, and a bad PRIORITY on a stream in flight are
 * stream errors: only that stream is invalid.
 * A connection that fails to open is counted (`connect_failed`), not a
 * request; it is retried after 10 ms.
 *
 * Prints one line of `key=value` fields: for the measured requests `sent`,
 * `ok`, `status`, `invalid`, `disconnected`, `timeout`; `ok_per_s`, the ok
 * answers that ended in the window (whenever sent) per second; the
 * measured ok answers' latency from when they were due `p50_us`, `p99_us`,
 * `max_us`; `inflight_end`, the requests sent before the window's end that
 * ended after it (their outcomes are counted, their ok answers are not in
 * `ok_per_s`), and `ok_late`, the measured ones of them that were ok; with
 * --rate, `rate`, then `queued` and `unsent` (above) of the measured
 * requests, and how long after it was due each measured request was sent,
 * `send_lag_p99_us` and `send_lag_max_us` (lag without `queued` is this
 * client's own delay); the
 * counts and latencies again for the slow requests with `slow_`, and for
 * those sent after SIGTERM with `after_`, then `after_connect_failed` and
 * `exit_ms` when PID ended after it (or `-`); `warmup_bad`, the warm-up
 * requests that were not ok; `srv_cpu_s` (PID's user and system CPU during the window, or up
 * to SIGTERM), `srv_cpu_us_per_ok` (that CPU time per ok answer that ended
 * in the window; `-` with SIGTERM), `srv_thread_cpu_s` (that CPU time per
 * thread of PID, busiest first, each thread that used at least 0.01 s: how
 * the CPU time spread, not where the connections were, since a handler
 * that waits uses none), `srv_rss_peak_kib` (VmHWM at its end)
 * and `srv_rss_kib` (VmRSS); `srv_conns_by_poller`, where PID's connections
 * were as the window began: for each of its epoll instances watching a
 * listening socket on P (one per worker's reactor, in Flare), the
 * established connections on P it watched, most first (`-` if none was
 * found; a connection the client opened after that moment, as h1 does after
 * a close, is not in it); `cli_cpu_s`, this client's own, and
 * `cli_thread_cpu_max_s`, the most of one of its threads; `connects`,
 * `connect_failed`, `stray` (h1 connections that sent
 * bytes with no request in flight, which this client then closed) and
 * `after_end` and `conn_errors` (above); then `invalid_as=`,
 * `disconnected_as=` and `conn_errors_as=` with up to four reasons and
 * their counts (warm-up included), and `status_as=` with the other
 * statuses. Exit status 0 if it ran, whatever it counted; 2 for
 * a usage or set-up error. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

enum { OK, STATUS, INVALID, DISCONNECTED, TIMEOUT, NOUT };
enum { G_WARM, G_MEAS, G_AFTER, NG };
enum { K_MAIN, K_SLOW, NK };
enum { MAXS = 128, RBUF = 1 << 16, HEAD_MAX = 16384, HBLOCK_MAX = 1 << 16 };

static const char *BROWSER[][2] = {
    {"User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
                   "Chrome/141.0.0.0 Safari/537.36"},
    {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
    {"Accept-Language", "ja,en-US;q=0.9,en;q=0.8"},
    {"Accept-Encoding", "gzip, deflate, br, zstd"},
    {"Connection", "keep-alive"},
    {"Cookie", "session=abc123; theme=dark"},
    {"Cookie", "lang=ja"},
    {"Upgrade-Insecure-Requests", "1"},
    {"Sec-Fetch-Dest", "document"},
    {"Sec-Fetch-Mode", "navigate"},
    {"Sec-Fetch-Site", "none"},
};
enum { NBROWSER = sizeof BROWSER / sizeof BROWSER[0] };

/* ---- settings and shared state ---- */

static int port, h2, nconns, nstreams = 1, nthreads = 1, slow_every, browser;
static double warmup_s, duration_s, timeout_s = 10.0, term_at_s = -1;
static double rate; /* --rate: requests per second, open loop; 0: closed loop */
static pid_t srv_pid;
static const char *require_name, *require_value, *content_type = "application/octet-stream";
static size_t require_name_len, require_value_len;

typedef struct {
    uint8_t *h1;  /* the whole HTTP/1.1 request, body included */
    size_t h1_len;
    uint8_t *block; /* its h2c header block (HPACK, no indexing, no Huffman) */
    size_t block_len;
    const uint8_t *body;
    size_t body_len;
    const uint8_t *expect;
    size_t expect_len;
} Req;
static Req reqs[NK];

static double t0, t_signal = -1; /* t_signal: when SIGTERM was sent, or -1 */
static int signalled; /* set (release) after t_signal; read with acquire */
static double linger_s = 0.3;

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void die(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "load: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(2);
}

static void *xrealloc(void *p, size_t n) {
    p = realloc(p, n ? n : 1);
    if (!p) die("out of memory");
    return p;
}

/* ---- statistics ---- */

typedef struct {
    uint64_t sent, out[NOUT];
    double *lat; /* microseconds, of the ok answers */
    size_t nlat, caplat;
} Bucket;

typedef struct {
    char text[96];
    uint64_t count;
} Reason;

typedef struct {
    Bucket b[NG][NK];
    uint64_t connects, connect_failed, after_connect_failed, stray, after_end, conn_errors;
    /* ok answers that ended inside the measured window, whenever sent (by
     * kind); requests sent before the window ended that ended after it, and
     * the measured ones of those that were ok */
    uint64_t ok_in_window[NK], inflight_end, ok_late;
    /* open loop: measured requests that waited for a free connection or
     * stream, and those due in the window that were never sent; how late
     * each measured request was sent (microseconds) */
    uint64_t queued, unsent;
    double *lag;
    size_t nlag, caplag;
    Reason why[4][8]; /* [0] invalid, [1] disconnected, [2] other statuses, [3] connection errors */
} Stats;

static void reason(Stats *s, int which, const char *text) {
    Reason *r = s->why[which];
    for (int i = 0; i < 8; i++) {
        if (r[i].count && strcmp(r[i].text, text) == 0) {
            r[i].count++;
            return;
        }
        if (!r[i].count) {
            snprintf(r[i].text, sizeof r[i].text, "%s", text);
            r[i].count = 1;
            return;
        }
    }
}

static int group_of(double t) {
    if (t < t0 + warmup_s) return G_WARM;
    if (__atomic_load_n(&signalled, __ATOMIC_ACQUIRE) && t >= t_signal) return G_AFTER;
    return G_MEAS;
}

/* ---- connections ---- */

enum { C_DOWN, C_CONNECTING, C_IDLE, C_BUSY };

typedef struct {
    int active, kind, group, began, head_done, failed, status, ok_body, has_required;
    uint32_t sid;
    double t_sent;
    double t_due; /* when it was due: t_sent in closed loop, its slot in the schedule in open loop */
    long clen; /* -1: none given */
    size_t got;
    size_t body_off;  /* h2c: request body bytes sent */
    int64_t send_window, recv_window;
    int headers_seen; /* h2c: the response HEADERS arrived */
    const char *fail; /* first reason it is invalid, if any */
} Stream;

typedef struct {
    char *name;
    size_t name_len;
    char *value;
    size_t value_len;
} Entry;

typedef struct {
    Entry *table; /* newest first */
    size_t n, cap, size, max_size;
} Hpack;

typedef struct Conn {
    int fd, state;
    uint32_t events; /* what epoll watches */
    double retry_at;
    /* writing: an h1 request is written straight from its Req; h2c frames
     * go through wbuf */
    const uint8_t *wsrc;
    size_t wsrc_len, woff;
    int write_failed;
    uint8_t *wbuf;
    size_t wlen, wcap, wsent;
    /* h1 response */
    Stream s; /* the request in flight (h1) */
    char head[HEAD_MAX];
    size_t hlen;
    int close_after;
    /* h2c */
    uint8_t *rbuf;
    size_t rlen, rcap;
    Stream st[MAXS];
    int nactive;
    uint32_t next_sid, peer_max_frame, peer_max_streams, goaway_last;
    int64_t conn_window, peer_init_window, recv_window;
    uint64_t recv_unacked;
    /* The streams this client reset (a timeout, a stream error): frames on
     * them may still arrive and are ignored. Any other stream below next_sid
     * that is not in flight ended by the server, and a frame on it but
     * RST_STREAM, WINDOW_UPDATE or PRIORITY is an error (RFC 9113 5.1). */
    uint32_t *reset;
    size_t nreset, capreset;
    int goaway;
    Hpack dec;
    uint8_t *hblock;
    size_t hblen;
    uint32_t hb_sid;
    int hb_end, in_headers;
    int broken; /* a protocol error: the connection is closed */
    int settings_seen; /* the server's preface, a SETTINGS frame, arrived */
} Conn;

typedef struct {
    int id, epfd, nconn;
    Conn *conns;
    Stats stats;
    uint64_t issued;
    /* open loop: this thread's next request in the schedule (sched), and
     * the first one that was not yet due with no connection or stream free */
    uint64_t next, blocked;
    double cpu_s; /* this thread's CPU time during the measured window */
    pthread_t thread;
} Worker;

static void stream_end(Worker *w, Stream *s, int outcome, const char *why) {
    Bucket *b = &w->stats.b[s->group][s->kind];
    b->out[outcome]++;
    double t = now(), from = t0 + warmup_s, to = from + duration_s;
    if (outcome == OK && t >= from && t < to) w->stats.ok_in_window[s->kind]++;
    if (s->t_sent < to && t >= to) {
        w->stats.inflight_end++;
        if (outcome == OK && s->group == G_MEAS) w->stats.ok_late++;
    }
    if (outcome == OK) {
        if (b->nlat == b->caplat) {
            b->caplat = b->caplat ? b->caplat * 2 : 4096;
            b->lat = xrealloc(b->lat, b->caplat * sizeof *b->lat);
        }
        b->lat[b->nlat++] = (t - s->t_due) * 1e6;
    } else if (outcome == INVALID) {
        reason(&w->stats, 0, why ? why : "?");
    } else if (outcome == DISCONNECTED) {
        reason(&w->stats, 1, why ? why : "?");
    } else if (outcome == STATUS) {
        char text[16];
        snprintf(text, sizeof text, "%d", s->status);
        reason(&w->stats, 2, text);
    }
    s->active = 0;
}

/* The outcome of a stream whose connection went away or that the server
 * reset: disconnected if no byte of its response arrived, else invalid. */
static void stream_cut(Worker *w, Stream *s, const char *why) {
    char text[96];
    if (s->began) {
        snprintf(text, sizeof text, "%s in the middle of a response", why);
        stream_end(w, s, INVALID, text);
    } else {
        stream_end(w, s, DISCONNECTED, why);
    }
}

static int issuing(double t) { return t < t0 + warmup_s + duration_s; }

/* Open loop: when this thread's i-th request is due. The threads' requests
 * interleave, so together they are due every 1/rate seconds from t0. */
static double sched(const Worker *w, uint64_t i) { return t0 + (double)(i * nthreads + w->id) / rate; }

/* Whether a request may be sent now, on a connection or stream that is
 * free, and when it was due. Closed loop: whenever the window is open, due
 * now. Open loop: this thread's next request, if it is due. */
static int take(Worker *w, double t, double *due) {
    if (!issuing(t)) return 0;
    if (!rate) {
        *due = t;
        return 1;
    }
    double d = sched(w, w->next);
    if (d > t) return 0;
    if (w->next < w->blocked && group_of(d) == G_MEAS) w->stats.queued++;
    w->next++;
    *due = d;
    return 1;
}

static void watch(Worker *w, Conn *c, uint32_t events) {
    if (c->events == events) return;
    c->events = events;
    struct epoll_event ev = {.events = events, .data.ptr = c};
    if (epoll_ctl(w->epfd, EPOLL_CTL_MOD, c->fd, &ev) < 0) die("epoll_ctl: %s", strerror(errno));
}

static void conn_close(Worker *w, Conn *c, const char *why) {
    if (c->fd >= 0) {
        epoll_ctl(w->epfd, EPOLL_CTL_DEL, c->fd, NULL);
        close(c->fd);
    }
    c->fd = -1;
    if (h2) {
        for (int i = 0; i < MAXS; i++)
            if (c->st[i].active) stream_cut(w, &c->st[i], why);
        c->nactive = 0;
    } else if (c->s.active) {
        stream_cut(w, &c->s, why);
    }
    c->state = C_DOWN;
    c->retry_at = 0;
}

static void connect_failed(Worker *w) {
    w->stats.connect_failed++;
    if (group_of(now()) == G_AFTER) w->stats.after_connect_failed++;
}

static void conn_open(Worker *w, Conn *c) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) die("socket: %s", strerror(errno));
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    c->fd = fd;
    c->state = C_CONNECTING;
    c->events = EPOLLOUT | EPOLLIN | EPOLLRDHUP;
    struct epoll_event ev = {.events = c->events, .data.ptr = c};
    if (epoll_ctl(w->epfd, EPOLL_CTL_ADD, fd, &ev) < 0) die("epoll_ctl: %s", strerror(errno));
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0 && errno != EINPROGRESS) {
        connect_failed(w);
        epoll_ctl(w->epfd, EPOLL_CTL_DEL, fd, NULL);
        close(fd);
        c->fd = -1;
        c->state = C_DOWN;
        c->retry_at = now() + 0.01;
    }
}

static void start_stream(Worker *w, Stream *s, double t, double due) {
    memset(s, 0, sizeof *s);
    s->active = 1;
    s->kind = (slow_every && ++w->issued % (uint64_t)slow_every == 0) ? K_SLOW : K_MAIN;
    s->group = group_of(due);
    s->t_sent = t;
    s->t_due = due;
    if (rate && s->group == G_MEAS) {
        Stats *st = &w->stats;
        if (st->nlag == st->caplag) {
            st->caplag = st->caplag ? st->caplag * 2 : 4096;
            st->lag = xrealloc(st->lag, st->caplag * sizeof *st->lag);
        }
        st->lag[st->nlag++] = (t - due) * 1e6;
    }
    s->clen = -1;
    s->ok_body = 1;
    w->stats.b[s->group][s->kind].sent++;
}

/* ---- HTTP/1.1 ---- */

static int is_tchar(unsigned char ch) {
    return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
           (ch && strchr("!#$%&'*+-.^_`|~", ch));
}

/* A byte RFC 9110 allows in no field value or reason phrase: a control
 * character other than HTAB, or DEL. */
static int is_ctl(unsigned char ch) { return (ch < 0x20 && ch != '\t') || ch == 0x7f; }

static void h1_flush(Worker *w, Conn *c) {
    while (c->woff < c->wsrc_len && !c->write_failed) {
        ssize_t n = send(c->fd, c->wsrc + c->woff, c->wsrc_len - c->woff, MSG_NOSIGNAL);
        if (n > 0) {
            c->woff += n;
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            watch(w, c, EPOLLIN | EPOLLOUT | EPOLLRDHUP);
            return;
        }
        /* The answer, if any, may still be readable: read until EOF. */
        c->write_failed = 1;
    }
    watch(w, c, EPOLLIN | EPOLLRDHUP);
}

static void h1_issue(Worker *w, Conn *c, double t, double due) {
    start_stream(w, &c->s, t, due);
    c->hlen = 0;
    c->close_after = 0;
    c->wsrc = reqs[c->s.kind].h1;
    c->wsrc_len = reqs[c->s.kind].h1_len;
    c->woff = 0;
    c->write_failed = 0;
    c->state = C_BUSY;
    h1_flush(w, c);
}

static int ieq(const char *a, size_t n, const char *lit) {
    return n == strlen(lit) && strncasecmp(a, lit, n) == 0;
}

/* Parses c->head (without its final CRLF CRLF); returns NULL or why it is
 * not well formed. */
static const char *h1_parse_head(Conn *c) {
    Stream *s = &c->s;
    char *p = c->head, *end = c->head + c->hlen;
    for (char *q = p; q < end; q++) {
        if (*q == '\0') return "a NUL in the head";
        if ((*q == '\r' && (q + 1 == end || q[1] != '\n')) || (*q == '\n' && (q == p || q[-1] != '\r')))
            return "a bare CR or LF in the head";
    }
    char *eol = memmem(p, end - p, "\r\n", 2);
    if (!eol) eol = end;
    size_t n = eol - p;
    /* status-line = HTTP-version SP status-code SP [ reason-phrase ]: the
     * second SP even with no reason (RFC 9112 section 4) */
    if (n < 13 || memcmp(p, "HTTP/1.1 ", 9) != 0 || p[9] < '1' || p[9] > '5' || p[10] < '0' ||
        p[10] > '9' || p[11] < '0' || p[11] > '9' || p[12] != ' ')
        return "status line";
    for (size_t i = 13; i < n; i++)
        if (is_ctl(p[i])) return "status line";
    s->status = (p[9] - '0') * 100 + (p[10] - '0') * 10 + (p[11] - '0');
    if (s->status < 200) return "an interim response";
    long length = -2;
    p = eol;
    while (p < end) {
        p += 2;
        eol = memmem(p, end - p, "\r\n", 2);
        if (!eol) eol = end;
        if (*p == ' ' || *p == '\t') return "obs-fold";
        char *colon = memchr(p, ':', eol - p);
        if (!colon || colon == p) return "a field line without a name";
        for (char *q = p; q < colon; q++)
            if (!is_tchar(*q)) return "a field name that is not a token";
        char *v = colon + 1, *ve = eol;
        for (char *q = v; q < ve; q++)
            if (is_ctl(*q)) return "a control character in a field value";
        while (v < ve && (*v == ' ' || *v == '\t')) v++;
        while (ve > v && (ve[-1] == ' ' || ve[-1] == '\t')) ve--;
        size_t nl = colon - p;
        if (ieq(p, nl, "transfer-encoding")) return "Transfer-Encoding";
        if (ieq(p, nl, "content-length")) {
            char *q = v;
            while (q < ve) { /* a list: every value the same */
                char *e = memchr(q, ',', ve - q);
                if (!e) e = ve;
                char *a = q, *b = e;
                while (a < b && (*a == ' ' || *a == '\t')) a++;
                while (b > a && (b[-1] == ' ' || b[-1] == '\t')) b--;
                if (a == b || b - a > 12) return "Content-Length";
                long x = 0;
                for (char *d = a; d < b; d++) {
                    if (*d < '0' || *d > '9') return "Content-Length";
                    x = x * 10 + (*d - '0');
                }
                if (length != -2 && length != x) return "Content-Length values that differ";
                length = x;
                q = e < ve ? e + 1 : ve;
            }
        }
        if (ieq(p, nl, "connection")) /* a list of tokens (RFC 9110 7.6.1) */
            for (char *q = v; q < ve;) {
                char *e = memchr(q, ',', ve - q);
                if (!e) e = ve;
                char *a = q, *b = e;
                while (a < b && (*a == ' ' || *a == '\t')) a++;
                while (b > a && (b[-1] == ' ' || b[-1] == '\t')) b--;
                if (ieq(a, b - a, "close")) c->close_after = 1;
                q = e < ve ? e + 1 : ve;
            }
        if (require_name && ieq(p, nl, require_name) && (size_t)(ve - v) == require_value_len &&
            memcmp(v, require_value, require_value_len) == 0)
            s->has_required = 1;
        p = eol;
    }
    if (s->status == 204 || s->status == 304) {
        if (s->status == 204 && length != -2) return "Content-Length on a 204";
        length = 0;
    } else if (length == -2) {
        return "no Content-Length";
    }
    s->clen = length;
    return NULL;
}

static void h1_complete(Worker *w, Conn *c) {
    Stream *s = &c->s;
    const Req *r = &reqs[s->kind];
    if (s->status != 200)
        stream_end(w, s, STATUS, NULL);
    else if (!s->ok_body || (size_t)s->clen != r->expect_len)
        stream_end(w, s, INVALID, "a body other than the expected one");
    else if (require_name && !s->has_required)
        stream_end(w, s, INVALID, "without the required header");
    else
        stream_end(w, s, OK, NULL);
    if (c->close_after || c->woff < c->wsrc_len) { /* answered before its request was written */
        conn_close(w, c, "closed");
        return;
    }
    c->state = C_IDLE;
}

/* Consumes n bytes the connection read. */
static void h1_input(Worker *w, Conn *c, const uint8_t *data, size_t n) {
    Stream *s = &c->s;
    while (n) {
        if (c->state != C_BUSY || !s->active) {
            /* Bytes with no request in flight: no request's outcome. */
            w->stats.stray++;
            conn_close(w, c, "stray bytes");
            return;
        }
        s->began = 1;
        if (!s->head_done) {
            size_t take = n;
            if (c->hlen + take > HEAD_MAX) take = HEAD_MAX - c->hlen;
            memcpy(c->head + c->hlen, data, take);
            size_t from = c->hlen > 3 ? c->hlen - 3 : 0;
            c->hlen += take;
            char *e = memmem(c->head + from, c->hlen - from, "\r\n\r\n", 4);
            if (!e) {
                if (c->hlen == HEAD_MAX) {
                    stream_end(w, s, INVALID, "a head over 16 KiB");
                    conn_close(w, c, "invalid");
                    return;
                }
                return;
            }
            size_t head_len = e - c->head;
            size_t used = head_len + 4 - (c->hlen - take);
            c->hlen = head_len;
            data += used;
            n -= used;
            s->head_done = 1;
            const char *bad = h1_parse_head(c);
            if (bad) {
                stream_end(w, s, INVALID, bad);
                conn_close(w, c, "invalid");
                return;
            }
        }
        size_t want = s->clen - s->got;
        size_t take = n < want ? n : want;
        const Req *r = &reqs[s->kind];
        if (s->ok_body && s->status == 200) {
            if (s->got + take > r->expect_len || memcmp(r->expect + s->got, data, take) != 0)
                s->ok_body = 0;
        }
        s->got += take;
        data += take;
        n -= take;
        if (s->got == (size_t)s->clen) {
            if (n) {
                stream_end(w, s, INVALID, "bytes after the body");
                conn_close(w, c, "invalid");
                return;
            }
            h1_complete(w, c);
            return;
        }
    }
}

/* ---- HPACK (RFC 7541): decoding with the dynamic table, no Huffman ---- */

static const char *STATIC[62][2] = {
    {"", ""}, {":authority", ""}, {":method", "GET"}, {":method", "POST"}, {":path", "/"},
    {":path", "/index.html"}, {":scheme", "http"}, {":scheme", "https"}, {":status", "200"},
    {":status", "204"}, {":status", "206"}, {":status", "304"}, {":status", "400"},
    {":status", "404"}, {":status", "500"}, {"accept-charset", ""},
    {"accept-encoding", "gzip, deflate"}, {"accept-language", ""}, {"accept-ranges", ""},
    {"accept", ""}, {"access-control-allow-origin", ""}, {"age", ""}, {"allow", ""},
    {"authorization", ""}, {"cache-control", ""}, {"content-disposition", ""},
    {"content-encoding", ""}, {"content-language", ""}, {"content-length", ""},
    {"content-location", ""}, {"content-range", ""}, {"content-type", ""}, {"cookie", ""},
    {"date", ""}, {"etag", ""}, {"expect", ""}, {"expires", ""}, {"from", ""}, {"host", ""},
    {"if-match", ""}, {"if-modified-since", ""}, {"if-none-match", ""}, {"if-range", ""},
    {"if-unmodified-since", ""}, {"last-modified", ""}, {"link", ""}, {"location", ""},
    {"max-forwards", ""}, {"proxy-authenticate", ""}, {"proxy-authorization", ""},
    {"range", ""}, {"referer", ""}, {"refresh", ""}, {"retry-after", ""}, {"server", ""},
    {"set-cookie", ""}, {"strict-transport-security", ""}, {"transfer-encoding", ""},
    {"user-agent", ""}, {"vary", ""}, {"via", ""}, {"www-authenticate", ""},
};

static int hp_int(const uint8_t *b, size_t n, size_t *i, int prefix, uint64_t *out) {
    if (*i >= n) return -1;
    uint64_t mask = (1u << prefix) - 1, v = b[(*i)++] & mask;
    if (v < mask) {
        *out = v;
        return 0;
    }
    for (int shift = 0; shift <= 28; shift += 7) {
        if (*i >= n) return -1;
        uint8_t byte = b[(*i)++];
        v += (uint64_t)(byte & 0x7f) << shift;
        if (!(byte & 0x80)) {
            *out = v;
            return 0;
        }
    }
    return -1;
}

static void hp_evict(Hpack *h) {
    while (h->size > h->max_size && h->n) {
        Entry *e = &h->table[--h->n];
        h->size -= e->name_len + e->value_len + 32;
        free(e->name);
        free(e->value);
    }
}

/* `name` and `value` may point into the table itself (a name taken from an
 * entry): both are copied before the table moves. */
static void hp_add(Hpack *h, const char *name, size_t nl, const char *value, size_t vl) {
    char *n = xrealloc(NULL, nl), *v = xrealloc(NULL, vl);
    memcpy(n, name, nl);
    memcpy(v, value, vl);
    if (h->n == h->cap) {
        h->cap = h->cap ? h->cap * 2 : 16;
        h->table = xrealloc(h->table, h->cap * sizeof *h->table);
    }
    memmove(h->table + 1, h->table, h->n * sizeof *h->table);
    Entry *e = &h->table[0];
    e->name = n;
    e->name_len = nl;
    e->value = v;
    e->value_len = vl;
    h->n++;
    h->size += nl + vl + 32;
    hp_evict(h);
}

static int hp_entry(Hpack *h, uint64_t index, const char **name, size_t *nl, const char **value,
                    size_t *vl) {
    if (index >= 1 && index <= 61) {
        *name = STATIC[index][0];
        *nl = strlen(*name);
        *value = STATIC[index][1];
        *vl = strlen(*value);
        return 0;
    }
    if (index < 62 || index - 62 >= h->n) return -1;
    Entry *e = &h->table[index - 62];
    *name = e->name;
    *nl = e->name_len;
    *value = e->value;
    *vl = e->value_len;
    return 0;
}

static int hp_string(const uint8_t *b, size_t n, size_t *i, const char **s, size_t *len, int *huff) {
    if (*i >= n) return -1;
    *huff = b[*i] & 0x80;
    uint64_t l;
    if (hp_int(b, n, i, 7, &l) < 0 || *i + l > n) return -1;
    *s = (const char *)b + *i;
    *len = l;
    *i += l;
    return 0;
}

/* One response field of a header block: returns NULL or why the block or the
 * field is not well formed. */
typedef struct {
    int status, regular, has_required;
    long clen;
} H2Head;

static const char *h2_field(H2Head *hd, const char *name, size_t nl, const char *value, size_t vl) {
    if (nl == 0) return "an empty field name";
    for (size_t i = name[0] == ':'; i < nl; i++) {
        unsigned char ch = name[i];
        if (!is_tchar(ch) || (ch >= 'A' && ch <= 'Z')) return "a field name that is not a lowercase token";
    }
    for (size_t i = 0; i < vl; i++)
        if (is_ctl(value[i])) return "a control character in a field value";
    if (vl && (value[0] == ' ' || value[0] == '\t' || value[vl - 1] == ' ' || value[vl - 1] == '\t'))
        return "whitespace around a value";
    if (name[0] == ':') {
        if (hd->regular || nl != 7 || memcmp(name, ":status", 7) != 0 || hd->status)
            return "a pseudo-header other than one :status first";
        if (vl != 3 || value[0] < '1' || value[0] > '5' || value[1] < '0' || value[1] > '9' ||
            value[2] < '0' || value[2] > '9')
            return ":status";
        hd->status = (value[0] - '0') * 100 + (value[1] - '0') * 10 + (value[2] - '0');
        return NULL;
    }
    hd->regular = 1;
    static const char *conn_specific[] = {"connection", "keep-alive", "proxy-connection",
                                          "transfer-encoding", "upgrade"};
    for (size_t i = 0; i < 5; i++)
        if (ieq(name, nl, conn_specific[i])) return "a connection-specific field";
    if (ieq(name, nl, "content-length")) {
        if (vl == 0 || vl > 12) return "content-length";
        long x = 0;
        for (size_t i = 0; i < vl; i++) {
            if (value[i] < '0' || value[i] > '9') return "content-length";
            x = x * 10 + (value[i] - '0');
        }
        if (hd->clen >= 0 && hd->clen != x) return "content-length values that differ";
        hd->clen = x;
    }
    if (require_name && ieq(name, nl, require_name) && vl == require_value_len &&
        memcmp(value, require_value, vl) == 0)
        hd->has_required = 1;
    return NULL;
}

/* Decodes a whole header block, updating the dynamic table whatever the
 * stream; returns NULL or why it is not well formed. A block that cannot
 * be decoded leaves the table unknown: the caller ends the connection. */
static const char *hp_decode(Hpack *h, const uint8_t *b, size_t n, H2Head *hd, int *fatal) {
    const char *bad = NULL;
    size_t i = 0;
    int fields = 0;
    *fatal = 0;
    while (i < n) {
        uint8_t byte = b[i];
        const char *name, *value;
        size_t nl, vl;
        uint64_t index;
        if (byte & 0x80) {
            if (hp_int(b, n, &i, 7, &index) < 0 || hp_entry(h, index, &name, &nl, &value, &vl) < 0) {
                *fatal = 1;
                return "an HPACK index not in the table";
            }
        } else if ((byte & 0xe0) == 0x20) {
            uint64_t size;
            if (fields || hp_int(b, n, &i, 5, &size) < 0 || size > 4096) {
                *fatal = 1;
                return "an HPACK table size update";
            }
            h->max_size = size;
            hp_evict(h);
            continue;
        } else {
            int indexing = (byte & 0xc0) == 0x40;
            if (hp_int(b, n, &i, indexing ? 6 : 4, &index) < 0) {
                *fatal = 1;
                return "an HPACK block cut short";
            }
            int huff = 0, huff2 = 0;
            if (index) {
                if (hp_entry(h, index, &name, &nl, &value, &vl) < 0) {
                    *fatal = 1;
                    return "an HPACK index not in the table";
                }
            } else if (hp_string(b, n, &i, &name, &nl, &huff) < 0) {
                *fatal = 1;
                return "an HPACK block cut short";
            }
            if (hp_string(b, n, &i, &value, &vl, &huff2) < 0) {
                *fatal = 1;
                return "an HPACK block cut short";
            }
            if (huff || huff2) {
                *fatal = 1; /* its size in the table is unknown */
                return "a Huffman-coded field, which this client does not decode";
            }
        }
        fields++;
        /* Checked before an insertion can move or evict the entry `name` is in. */
        const char *why = h2_field(hd, name, nl, value, vl);
        if (why && !bad) bad = why;
        if (!(byte & 0x80) && (byte & 0xc0) == 0x40) hp_add(h, name, nl, value, vl);
    }
    if (!bad && !hd->status) bad = "no :status";
    return bad;
}

/* ---- h2c ---- */

static void wput(Conn *c, const void *data, size_t n) {
    if (c->wlen + n > c->wcap) {
        while (c->wlen + n > c->wcap) c->wcap = c->wcap ? c->wcap * 2 : 65536;
        c->wbuf = xrealloc(c->wbuf, c->wcap);
    }
    memcpy(c->wbuf + c->wlen, data, n);
    c->wlen += n;
}

static void frame(Conn *c, int type, int flags, uint32_t sid, const void *payload, size_t n) {
    uint8_t h[9] = {n >> 16, n >> 8, n, type, flags, sid >> 24, sid >> 16, sid >> 8, sid};
    wput(c, h, 9);
    if (n) wput(c, payload, n);
}

static void window_update(Conn *c, uint32_t sid, uint32_t inc) {
    uint8_t p[4] = {inc >> 24, inc >> 16, inc >> 8, inc};
    frame(c, 8, 0, sid, p, 4);
}

static void h2_flush(Worker *w, Conn *c) {
    while (c->wsent < c->wlen) {
        ssize_t n = send(c->fd, c->wbuf + c->wsent, c->wlen - c->wsent, MSG_NOSIGNAL);
        if (n > 0) {
            c->wsent += n;
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            watch(w, c, EPOLLIN | EPOLLOUT | EPOLLRDHUP);
            return;
        }
        c->write_failed = 1; /* read what is left, then the EOF ends it */
        c->wsent = c->wlen;
    }
    c->wsent = c->wlen = 0;
    watch(w, c, EPOLLIN | EPOLLRDHUP);
}

static Stream *h2_stream(Conn *c, uint32_t sid) {
    for (int i = 0; i < MAXS; i++)
        if (c->st[i].active && c->st[i].sid == sid) return &c->st[i];
    return NULL;
}

static void reset_stream(Conn *c, Stream *s, uint32_t code) {
    uint8_t p[4] = {code >> 24, code >> 16, code >> 8, code};
    frame(c, 3, 0, s->sid, p, 4);
    if (c->nreset == c->capreset) {
        c->capreset = c->capreset ? c->capreset * 2 : 16;
        c->reset = xrealloc(c->reset, c->capreset * sizeof *c->reset);
    }
    c->reset[c->nreset++] = s->sid;
}

static int was_reset(Conn *c, uint32_t sid) {
    for (size_t i = 0; i < c->nreset; i++)
        if (c->reset[i] == sid) return 1;
    return 0;
}

/* Queues DATA for the streams with request body left, as far as the
 * windows allow. */
static void h2_pump(Conn *c) {
    for (int i = 0; i < MAXS && c->wlen < (1u << 18); i++) {
        Stream *s = &c->st[i];
        if (!s->active) continue;
        const Req *r = &reqs[s->kind];
        while (r->body_len && s->body_off < r->body_len && c->conn_window > 0 && s->send_window > 0 &&
               c->wlen < (1u << 18)) {
            size_t n = r->body_len - s->body_off;
            if (n > c->peer_max_frame) n = c->peer_max_frame;
            if ((int64_t)n > c->conn_window) n = c->conn_window;
            if ((int64_t)n > s->send_window) n = s->send_window;
            int end = s->body_off + n == r->body_len;
            frame(c, 0, end ? 1 : 0, s->sid, r->body + s->body_off, n);
            s->body_off += n;
            c->conn_window -= n;
            s->send_window -= n;
        }
    }
}

static void h2_connected(Conn *c) {
    static const char preface[] = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    wput(c, preface, 24);
    /* ENABLE_PUSH 0, INITIAL_WINDOW_SIZE 16 MiB */
    uint8_t settings[12] = {0, 2, 0, 0, 0, 0, 0, 4, 1, 0, 0, 0};
    frame(c, 4, 0, 0, settings, sizeof settings);
    window_update(c, 0, (1u << 24) - 65535);
    c->next_sid = 1;
    c->peer_max_frame = 16384;
    c->peer_max_streams = 100;
    c->conn_window = 65535;
    c->peer_init_window = 65535;
    c->goaway = 0;
    c->broken = 0;
    c->settings_seen = 0;
    c->rlen = 0;
    c->in_headers = 0;
    c->recv_unacked = 0;
    c->recv_window = 1 << 24;
    c->nreset = 0;
    c->nactive = 0;
    for (size_t i = 0; i < c->dec.n; i++) {
        free(c->dec.table[i].name);
        free(c->dec.table[i].value);
    }
    c->dec.n = c->dec.size = 0;
    c->dec.max_size = 4096;
}

/* Sends a request on a free stream if take allows; returns whether it did. */
static int h2_issue(Worker *w, Conn *c, double t) {
    Stream *s = NULL;
    for (int i = 0; i < MAXS; i++)
        if (!c->st[i].active) {
            s = &c->st[i];
            break;
        }
    double due;
    if (!s || !take(w, t, &due)) return 0;
    start_stream(w, s, t, due);
    s->sid = c->next_sid;
    c->next_sid += 2;
    s->send_window = c->peer_init_window;
    s->recv_window = 1 << 24; /* this client's SETTINGS_INITIAL_WINDOW_SIZE */
    const Req *r = &reqs[s->kind];
    frame(c, 1, r->body_len ? 4 : 5, s->sid, r->block, r->block_len); /* END_HEADERS (| END_STREAM) */
    c->nactive++;
    return 1;
}

static void h2_fill(Worker *w, Conn *c, double t) {
    if (c->state != C_IDLE && c->state != C_BUSY) return;
    if (!c->goaway) {
        /* SETTINGS_MAX_CONCURRENT_STREAMS is any 32-bit value */
        uint32_t limit = (uint32_t)nstreams < c->peer_max_streams ? (uint32_t)nstreams : c->peer_max_streams;
        while ((uint32_t)c->nactive < limit && c->next_sid < 0x7fffff00u && h2_issue(w, c, t)) {
        }
    }
    c->state = c->nactive ? C_BUSY : C_IDLE;
    h2_pump(c);
    h2_flush(w, c);
}

/* A connection error (RFC 9113 5.4.1): counted with its reason whether or
 * not a stream was in flight, and every stream in flight is invalid. */
static void h2_fail(Worker *w, Conn *c, const char *why) {
    w->stats.conn_errors++;
    reason(&w->stats, 3, why);
    for (int i = 0; i < MAXS; i++)
        if (c->st[i].active) stream_end(w, &c->st[i], INVALID, why);
    c->nactive = 0;
    c->broken = 1;
    conn_close(w, c, "invalid");
}

/* A stream error (RFC 9113 5.4.2): the stream is invalid and reset. */
static void stream_error(Worker *w, Conn *c, Stream *s, const char *why, uint32_t code) {
    stream_end(w, s, INVALID, why);
    c->nactive--;
    reset_stream(c, s, code);
}

/* A frame the server sent on a stream after it ended the stream: counted
 * apart (`after_end`), since that stream's outcome is already counted, and
 * a connection error, so every stream in flight on it is invalid. */
static void after_end(Worker *w, Conn *c, const char *what) {
    char why[96];
    w->stats.after_end++;
    snprintf(why, sizeof why, "%s on a stream the server had ended", what);
    h2_fail(w, c, why);
}

/* Whether sid names an idle stream (RFC 9113 5.1): one this client has not
 * opened; with push off, every even one. */
static int idle_stream(Conn *c, uint32_t sid) { return !(sid & 1) || sid >= c->next_sid; }

/* Whether sid names a stream this client opened that is no longer in
 * flight and that it did not reset itself. */
static int ended_by_server(Conn *c, uint32_t sid) {
    return (sid & 1) && sid < c->next_sid && !h2_stream(c, sid) && !was_reset(c, sid);
}

static void h2_finish(Worker *w, Conn *c, Stream *s) {
    const Req *r = &reqs[s->kind];
    if (s->fail)
        stream_end(w, s, INVALID, s->fail);
    else if (s->clen >= 0 && (size_t)s->clen != s->got)
        stream_end(w, s, INVALID, "content-length other than the DATA received");
    else if (s->status != 200)
        stream_end(w, s, STATUS, NULL);
    else if (!s->ok_body || s->got != r->expect_len)
        stream_end(w, s, INVALID, "a body other than the expected one");
    else if (require_name && !s->has_required)
        stream_end(w, s, INVALID, "without the required header");
    else
        stream_end(w, s, OK, NULL);
    c->nactive--;
    if (r->body_len && s->body_off < r->body_len) {
        /* Answered before its body was sent: stop sending it. */
        uint8_t code[4] = {0, 0, 0, 0}; /* NO_ERROR */
        frame(c, 3, 0, s->sid, code, 4);
    }
}

static void h2_headers_done(Worker *w, Conn *c) {
    H2Head hd = {.clen = -1};
    int fatal;
    const char *bad = hp_decode(&c->dec, c->hblock, c->hblen, &hd, &fatal);
    c->in_headers = 0;
    Stream *s = h2_stream(c, c->hb_sid);
    if (!s && ended_by_server(c, c->hb_sid)) {
        after_end(w, c, "HEADERS"); /* whether or not its block decodes */
        return;
    }
    if (fatal) {
        h2_fail(w, c, bad);
        return;
    }
    if (!s) return; /* one this client reset */
    if (s->headers_seen) {
        if (!s->fail) s->fail = "trailers or a second response head";
    } else {
        s->headers_seen = 1;
        if (bad && !s->fail) s->fail = bad;
        if (hd.status && hd.status < 200 && !s->fail) s->fail = "an interim response";
        s->status = hd.status;
        s->clen = hd.clen;
        s->has_required = hd.has_required;
    }
    if (c->hb_end) h2_finish(w, c, s);
}

static int unpad(const uint8_t **p, size_t *n, int flags) {
    if (!(flags & 0x8)) return 0;
    if (*n < 1) return -1;
    size_t pad = (*p)[0];
    if (pad + 1 > *n) return -1;
    *p += 1;
    *n -= pad + 1;
    return 0;
}

static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

/* Handles one frame; returns -1 once the connection is gone. */
static int h2_frame(Worker *w, Conn *c, int type, int flags, uint32_t sid, const uint8_t *p, size_t n) {
    if (!c->settings_seen) { /* the server's connection preface (RFC 9113 3.4) */
        if (type != 4 || (flags & 1)) {
            h2_fail(w, c, "a first frame other than SETTINGS");
            return -1;
        }
        c->settings_seen = 1;
    }
    if (c->in_headers && type != 9) {
        h2_fail(w, c, "a frame inside a header block");
        return -1;
    }
    switch (type) {
    case 0: { /* DATA */
        if (!sid) {
            h2_fail(w, c, "DATA on stream 0");
            return -1;
        }
        size_t whole = n; /* flow control counts the padding too */
        c->recv_unacked += n;
        c->recv_window -= n;
        if (c->recv_window < 0) {
            h2_fail(w, c, "DATA beyond the connection's flow-control window");
            return -1;
        }
        if (unpad(&p, &n, flags) < 0) {
            h2_fail(w, c, "padding");
            return -1;
        }
        Stream *s = h2_stream(c, sid);
        if (!s) {
            if (idle_stream(c, sid)) {
                h2_fail(w, c, "DATA on a stream this client did not open");
                return -1;
            }
            if (!was_reset(c, sid)) {
                after_end(w, c, "DATA");
                return -1;
            }
            return 0;
        }
        s->recv_window -= whole;
        if (s->recv_window < 0) {
            stream_error(w, c, s, "DATA beyond the stream's flow-control window", 3);
            return 0;
        }
        s->began = 1;
        if (!s->headers_seen && !s->fail) s->fail = "DATA before the response head";
        const Req *r = &reqs[s->kind];
        if (s->ok_body && (s->got + n > r->expect_len || memcmp(r->expect + s->got, p, n) != 0))
            s->ok_body = 0;
        s->got += n;
        if (flags & 1) {
            h2_finish(w, c, s);
        } else if (whole) {
            window_update(c, sid, whole);
            s->recv_window += whole;
        }
        return 0;
    }
    case 1: /* HEADERS */
    case 9: { /* CONTINUATION */
        if (!sid || idle_stream(c, sid)) {
            h2_fail(w, c, "a header block on a stream this client did not open");
            return -1;
        }
        if (type == 9 && (!c->in_headers || sid != c->hb_sid)) {
            h2_fail(w, c, "CONTINUATION without HEADERS");
            return -1;
        }
        if (type == 1) {
            if (unpad(&p, &n, flags) < 0) {
                h2_fail(w, c, "padding");
                return -1;
            }
            if (flags & 0x20) { /* PRIORITY */
                if (n < 5) {
                    h2_fail(w, c, "a HEADERS frame cut short");
                    return -1;
                }
                Stream *s = h2_stream(c, sid);
                if (s && (be32(p) & 0x7fffffff) == sid && !s->fail) /* RFC 9113 5.3.1 */
                    s->fail = "a stream that depends on itself";
                p += 5;
                n -= 5;
            }
            c->hblen = 0;
            c->hb_sid = sid;
            c->hb_end = flags & 1;
            c->in_headers = 1;
        }
        if (c->hblen + n > HBLOCK_MAX) {
            h2_fail(w, c, "a header block over 64 KiB");
            return -1;
        }
        memcpy(c->hblock + c->hblen, p, n);
        c->hblen += n;
        Stream *s = h2_stream(c, sid);
        if (s) s->began = 1;
        if (flags & 4) {
            h2_headers_done(w, c);
            if (c->fd < 0) return -1;
        }
        return 0;
    }
    case 3: { /* RST_STREAM */
        if (n != 4 || !sid) {
            h2_fail(w, c, "RST_STREAM");
            return -1;
        }
        Stream *s = h2_stream(c, sid);
        if (!s && idle_stream(c, sid)) {
            h2_fail(w, c, "RST_STREAM on an idle stream");
            return -1;
        }
        if (s) {
            uint32_t code = be32(p);
            char why[64];
            snprintf(why, sizeof why, "RST_STREAM %u", code);
            /* NO_ERROR after a whole response is a server ending the upload */
            stream_cut(w, s, why);
            c->nactive--;
        }
        return 0;
    }
    case 4: { /* SETTINGS */
        if (sid || (flags & 1 ? n != 0 : n % 6)) {
            h2_fail(w, c, "SETTINGS");
            return -1;
        }
        if (flags & 1) return 0;
        for (size_t i = 0; i + 6 <= n; i += 6) {
            uint32_t id = (p[i] << 8) | p[i + 1], v = be32(p + i + 2);
            if (id == 2 && v != 0) { /* a server may send 0 only (RFC 9113 6.5.2) */
                h2_fail(w, c, "SETTINGS_ENABLE_PUSH other than 0");
                return -1;
            }
            if (id == 3) c->peer_max_streams = v;
            if (id == 4) {
                if (v > 0x7fffffff) {
                    h2_fail(w, c, "SETTINGS_INITIAL_WINDOW_SIZE");
                    return -1;
                }
                int64_t delta = (int64_t)v - c->peer_init_window;
                c->peer_init_window = v;
                for (int k = 0; k < MAXS; k++)
                    if (c->st[k].active) {
                        c->st[k].send_window += delta;
                        if (c->st[k].send_window > 0x7fffffff) {
                            h2_fail(w, c, "a stream flow-control window over 2^31-1");
                            return -1;
                        }
                    }
            }
            if (id == 5) {
                if (v < 16384 || v > 16777215) {
                    h2_fail(w, c, "SETTINGS_MAX_FRAME_SIZE");
                    return -1;
                }
                c->peer_max_frame = v;
            }
        }
        frame(c, 4, 1, 0, NULL, 0);
        return 0;
    }
    case 5:
        h2_fail(w, c, "PUSH_PROMISE");
        return -1;
    case 6: /* PING */
        if (n != 8 || sid) {
            h2_fail(w, c, "PING");
            return -1;
        }
        if (!(flags & 1)) frame(c, 6, 1, 0, p, 8);
        return 0;
    case 7: { /* GOAWAY */
        if (n < 8 || sid) {
            h2_fail(w, c, "GOAWAY");
            return -1;
        }
        c->goaway = 1;
        c->goaway_last = be32(p) & 0x7fffffff;
        for (int i = 0; i < MAXS; i++) {
            Stream *s = &c->st[i];
            if (s->active && s->sid > c->goaway_last) {
                stream_cut(w, s, "refused by GOAWAY");
                c->nactive--;
            }
        }
        return 0;
    }
    case 8: { /* WINDOW_UPDATE */
        if (n != 4) {
            h2_fail(w, c, "WINDOW_UPDATE");
            return -1;
        }
        uint32_t inc = be32(p) & 0x7fffffff;
        if (!sid) {
            if (!inc) {
                h2_fail(w, c, "a WINDOW_UPDATE of 0 on the connection");
                return -1;
            }
            c->conn_window += inc;
            if (c->conn_window > 0x7fffffff) {
                h2_fail(w, c, "a connection flow-control window over 2^31-1");
                return -1;
            }
        } else {
            Stream *s = h2_stream(c, sid);
            if (!s && idle_stream(c, sid)) {
                h2_fail(w, c, "WINDOW_UPDATE on an idle stream");
                return -1;
            }
            if (!s) return 0; /* a closed stream: allowed, ignored */
            if (!inc) {
                stream_error(w, c, s, "a WINDOW_UPDATE of 0 on its stream", 1);
                return 0;
            }
            s->send_window += inc;
            if (s->send_window > 0x7fffffff)
                stream_error(w, c, s, "a stream flow-control window over 2^31-1", 3);
        }
        return 0;
    }
    case 2: { /* PRIORITY: allowed on any stream but 0, idle ones included */
        Stream *s = h2_stream(c, sid);
        const char *bad = !sid ? "PRIORITY on stream 0"
                          : n != 5 ? "a PRIORITY frame not 5 bytes long"
                          : (be32(p) & 0x7fffffff) == sid ? "a stream that depends on itself"
                                                          : NULL;
        if (!bad) return 0;
        if (s) { /* a stream error */
            stream_error(w, c, s, bad, n != 5 ? 6 : 1);
            return 0;
        }
        /* on stream 0, or a stream error on no stream in flight, which RFC
         * 9113 5.4.1 lets an endpoint treat as a connection error */
        h2_fail(w, c, bad);
        return -1;
    }
    default:
        return 0; /* unknown frames */
    }
}

static void h2_input(Worker *w, Conn *c, const uint8_t *data, size_t n) {
    if (c->rlen + n > c->rcap) {
        while (c->rlen + n > c->rcap) c->rcap = c->rcap ? c->rcap * 2 : RBUF * 2;
        c->rbuf = xrealloc(c->rbuf, c->rcap);
    }
    memcpy(c->rbuf + c->rlen, data, n);
    c->rlen += n;
    size_t off = 0;
    while (c->rlen - off >= 9) {
        const uint8_t *h = c->rbuf + off;
        size_t len = ((size_t)h[0] << 16) | (h[1] << 8) | h[2];
        if (len > 16384) {
            h2_fail(w, c, "a frame over 16384 bytes");
            return;
        }
        if (c->rlen - off < 9 + len) break;
        if (h2_frame(w, c, h[3], h[4], be32(h + 5) & 0x7fffffff, h + 9, len) < 0) return;
        off += 9 + len;
    }
    memmove(c->rbuf, c->rbuf + off, c->rlen - off);
    c->rlen -= off;
    if (c->recv_unacked >= (1u << 20)) {
        window_update(c, 0, c->recv_unacked);
        c->recv_window += c->recv_unacked;
        c->recv_unacked = 0;
    }
}

/* The connection ended with part of a frame read, or between a HEADERS
 * frame and its last CONTINUATION: a connection error. If the frame header
 * arrived and names a stream in flight, part of that stream's response
 * arrived, so conn_close counts it invalid. */
static void h2_cut(Worker *w, Conn *c, const char *why) {
    char text[96];
    snprintf(text, sizeof text, "%s in the middle of a %s", why, c->rlen ? "frame" : "header block");
    w->stats.conn_errors++;
    reason(&w->stats, 3, text);
    if (c->rlen >= 9) {
        Stream *s = h2_stream(c, be32(c->rbuf + 5) & 0x7fffffff);
        if (s) s->began = 1;
    }
}

/* ---- the loop ---- */

static void on_connected(Worker *w, Conn *c) {
    int err = 0;
    socklen_t len = sizeof err;
    getsockopt(c->fd, SOL_SOCKET, SO_ERROR, &err, &len);
    if (err) {
        connect_failed(w);
        epoll_ctl(w->epfd, EPOLL_CTL_DEL, c->fd, NULL);
        close(c->fd);
        c->fd = -1;
        c->state = C_DOWN;
        c->retry_at = now() + 0.01;
        return;
    }
    w->stats.connects++;
    c->state = C_IDLE;
    c->write_failed = 0;
    c->wlen = c->wsent = 0;
    if (h2) h2_connected(c);
    watch(w, c, EPOLLIN | EPOLLRDHUP);
}

static void on_readable(Worker *w, Conn *c) {
    static __thread uint8_t buf[RBUF];
    for (int rounds = 0; rounds < 16 && c->fd >= 0; rounds++) {
        ssize_t n = recv(c->fd, buf, sizeof buf, 0);
        if (n > 0) {
            if (h2)
                h2_input(w, c, buf, n);
            else
                h1_input(w, c, buf, n);
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        const char *why = n == 0 ? "closed" : (errno == ECONNRESET ? "reset" : "read error");
        if (h2 && (c->rlen || c->in_headers)) h2_cut(w, c, why);
        conn_close(w, c, why);
        return;
    }
}

static int outstanding(Worker *w) {
    for (int i = 0; i < w->nconn; i++) {
        Conn *c = &w->conns[i];
        if (h2 ? c->nactive > 0 : c->s.active) return 1;
    }
    return 0;
}

static void expire(Worker *w, double t) {
    for (int i = 0; i < w->nconn; i++) {
        Conn *c = &w->conns[i];
        if (c->fd < 0) continue;
        if (!h2) {
            if (c->s.active && t - c->s.t_sent > timeout_s) {
                stream_end(w, &c->s, TIMEOUT, NULL);
                conn_close(w, c, "timeout");
            }
            continue;
        }
        for (int k = 0; k < MAXS; k++) {
            Stream *s = &c->st[k];
            if (s->active && t - s->t_sent > timeout_s) {
                stream_end(w, s, TIMEOUT, NULL);
                c->nactive--;
                reset_stream(c, s, 8); /* CANCEL */
            }
        }
    }
}

static double thread_cpu(void) {
    struct timespec ts;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void *run(void *arg) {
    Worker *w = arg;
    w->epfd = epoll_create1(EPOLL_CLOEXEC);
    if (w->epfd < 0) die("epoll_create1: %s", strerror(errno));
    for (int i = 0; i < w->nconn; i++) {
        Conn *c = &w->conns[i];
        c->fd = -1;
        if (h2) c->hblock = xrealloc(NULL, HBLOCK_MAX);
        conn_open(w, c);
    }
    double last_expire = 0, idle_since = -1, cpu_from = -1, wait = 0.005;
    int cpu_done = 0;
    struct epoll_event evs[256];
    for (;;) {
        double t = now();
        if (cpu_from < 0 && t >= t0 + warmup_s) cpu_from = thread_cpu();
        if (cpu_from >= 0 && !cpu_done && !issuing(t)) {
            w->cpu_s = thread_cpu() - cpu_from;
            cpu_done = 1;
        }
        if (!issuing(t) && !outstanding(w)) {
            /* Linger: what the server sends after the last answer is still
             * read and checked (stray bytes, frames after a stream's end,
             * connection errors) until linger_s passes with nothing in
             * flight; anything later is not seen. */
            if (idle_since < 0) idle_since = t;
            if (t - idle_since >= linger_s) break;
        }
        struct timespec ts = {0, (long)(wait * 1e9)};
        int n = epoll_pwait2(w->epfd, evs, 256, &ts, NULL);
        if (n < 0 && errno != EINTR) die("epoll_wait: %s", strerror(errno));
        for (int i = 0; i < n; i++) {
            Conn *c = evs[i].data.ptr;
            if (c->fd < 0) continue;
            if (c->state == C_CONNECTING) {
                if (evs[i].events & (EPOLLOUT | EPOLLERR | EPOLLHUP)) on_connected(w, c);
                continue;
            }
            if (evs[i].events & (EPOLLIN | EPOLLRDHUP | EPOLLERR | EPOLLHUP)) on_readable(w, c);
            if (c->fd >= 0 && (evs[i].events & EPOLLOUT)) {
                if (h2) {
                    h2_pump(c);
                    h2_flush(w, c);
                } else {
                    h1_flush(w, c);
                }
            }
        }
        t = now();
        if (t - last_expire > 0.02) {
            expire(w, t);
            last_expire = t;
        }
        for (int i = 0; i < w->nconn; i++) {
            Conn *c = &w->conns[i];
            if (c->state == C_DOWN) {
                if (issuing(t) && t >= c->retry_at) conn_open(w, c);
                continue;
            }
            if (h2) {
                if (c->fd >= 0 && c->goaway && !c->nactive) {
                    conn_close(w, c, "goaway");
                    continue;
                }
                if (c->fd >= 0) h2_fill(w, c, t);
            } else if (c->state == C_IDLE) {
                double due;
                if (take(w, t, &due)) h1_issue(w, c, t, due);
            }
        }
        wait = 0.005;
        if (rate && issuing(t)) {
            /* Every request due by now that is still unsent found no free
             * connection or stream: it is queued. Then wait for an event,
             * or until the next one is due. */
            if (w->blocked < w->next) w->blocked = w->next;
            while (sched(w, w->blocked) <= t) w->blocked++;
            wait = w->blocked > w->next ? 0.005 : sched(w, w->next) - now();
            if (wait > 0.005) wait = 0.005;
            if (wait < 0) wait = 0;
        }
    }
    if (rate) /* what the window left unsent when it closed */
        for (uint64_t i = w->next;; i++) {
            double d = sched(w, i);
            if (!issuing(d)) break;
            if (group_of(d) == G_MEAS) w->stats.unsent++;
        }
    for (int i = 0; i < w->nconn; i++)
        if (w->conns[i].fd >= 0) close(w->conns[i].fd);
    return NULL;
}

/* ---- set-up and report ---- */

static uint8_t *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) die("%s: %s", path, strerror(errno));
    uint8_t *data = NULL;
    size_t n = 0, cap = 0;
    for (;;) {
        if (n == cap) data = xrealloc(data, cap = cap ? cap * 2 : 65536);
        size_t got = fread(data + n, 1, cap - n, f);
        n += got;
        if (got == 0) break;
    }
    fclose(f);
    *len = n;
    return data;
}

static void put_lit(uint8_t **b, size_t *n, size_t *cap, const char *name, const char *value) {
    /* Literal without indexing, new name, no Huffman (RFC 7541 6.2.2). */
    size_t nl = strlen(name), vl = strlen(value);
    if (nl > 126 || vl > 126 * 128) die("field too long");
    while (*n + nl + vl + 8 > *cap) *b = xrealloc(*b, *cap = *cap ? *cap * 2 : 1024);
    (*b)[(*n)++] = 0;
    (*b)[(*n)++] = nl;
    for (size_t i = 0; i < nl; i++) {
        char ch = name[i];
        (*b)[(*n)++] = (ch >= 'A' && ch <= 'Z') ? ch + 32 : ch;
    }
    if (vl < 127) {
        (*b)[(*n)++] = vl;
    } else {
        (*b)[(*n)++] = 127;
        size_t rest = vl - 127;
        while (rest >= 128) {
            (*b)[(*n)++] = (rest & 0x7f) | 0x80;
            rest >>= 7;
        }
        (*b)[(*n)++] = rest;
    }
    memcpy(*b + *n, value, vl);
    *n += vl;
}

static void build(Req *r, const char *method, const char *path, const uint8_t *body, size_t body_len) {
    char head[8192];
    int k = snprintf(head, sizeof head, "%s %s HTTP/1.1\r\nHost: 127.0.0.1\r\n", method, path);
    if (browser)
        for (int i = 0; i < NBROWSER; i++)
            k += snprintf(head + k, sizeof head - k, "%s: %s\r\n", BROWSER[i][0], BROWSER[i][1]);
    if (body)
        k += snprintf(head + k, sizeof head - k, "Content-Type: %s\r\nContent-Length: %zu\r\n", content_type,
                      body_len);
    k += snprintf(head + k, sizeof head - k, "\r\n");
    r->h1_len = k + body_len;
    r->h1 = xrealloc(NULL, r->h1_len);
    memcpy(r->h1, head, k);
    if (body_len) memcpy(r->h1 + k, body, body_len);
    size_t n = 0, cap = 0;
    uint8_t *b = NULL;
    put_lit(&b, &n, &cap, ":method", method);
    put_lit(&b, &n, &cap, ":scheme", "http");
    put_lit(&b, &n, &cap, ":path", path);
    put_lit(&b, &n, &cap, ":authority", "127.0.0.1");
    if (browser)
        for (int i = 0; i < NBROWSER; i++)
            if (strcasecmp(BROWSER[i][0], "Connection") != 0) put_lit(&b, &n, &cap, BROWSER[i][0], BROWSER[i][1]);
    if (body) {
        char len[32];
        snprintf(len, sizeof len, "%zu", body_len);
        put_lit(&b, &n, &cap, "content-type", content_type);
        put_lit(&b, &n, &cap, "content-length", len);
    }
    if (n > 16384) die("request header block over one frame");
    r->block = b;
    r->block_len = n;
    r->body = body;
    r->body_len = body ? body_len : 0;
}

static void put_field(char *out, size_t *n, size_t cap, const char *name, const char *value) {
    int k = snprintf(out + *n, cap - *n, "%s: %s\n", name, value);
    if (k < 0 || (size_t)k >= cap - *n) die("--expect-fields: too long");
    *n += k;
}

/* What bench/load's servers answer to `GET /headers` (server_muntin.mojo,
 * `fields`) for the request this client sends: every field but Host and
 * Cookie, in order, with its name as sent (h2c: lowercase, no Connection);
 * then the values of four names looked up in another casing. Over h2c the
 * two Cookie fields arrive as one, joined with "; " (RFC 9113 8.2.3). */
static uint8_t *fields_echo(size_t *len) {
    size_t cap = 16384, n = 0;
    char *out = xrealloc(NULL, cap), lower[64];
    for (int i = 0; browser && i < NBROWSER; i++) {
        const char *name = BROWSER[i][0];
        if (strcasecmp(name, "cookie") == 0 || (h2 && strcasecmp(name, "connection") == 0)) continue;
        size_t k = 0;
        for (; name[k] && k < sizeof lower - 1; k++) lower[k] = h2 && name[k] >= 'A' && name[k] <= 'Z' ? name[k] + 32 : name[k];
        lower[k] = 0;
        put_field(out, &n, cap, lower, BROWSER[i][1]);
    }
    static const char *lookups[][2] = {{"COOKIE", "cookie"}, {"Accept-Language", "accept-language"}};
    for (int l = 0; l < 2; l++) {
        const char *values[NBROWSER];
        int count = 0;
        for (int i = 0; browser && i < NBROWSER; i++)
            if (strcasecmp(BROWSER[i][0], lookups[l][1]) == 0) values[count++] = BROWSER[i][1];
        char joined[1024] = "";
        if (h2 && l == 0 && count > 1) {
            size_t j = 0;
            for (int i = 0; i < count; i++) j += snprintf(joined + j, sizeof joined - j, "%s%s", i ? "; " : "", values[i]);
            values[0] = joined;
            count = 1;
        }
        n += snprintf(out + n, cap - n, "%s=%d\n", lookups[l][0], count);
        for (int i = 0; i < count; i++) put_field(out, &n, cap, lookups[l][0], values[i]);
    }
    n += snprintf(out + n, cap - n, "HOST=1\n");
    put_field(out, &n, cap, "HOST", "127.0.0.1");
    n += snprintf(out + n, cap - n, "X-Absent=0\n");
    *len = n;
    return (uint8_t *)out;
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static void merge(Bucket *into, const Bucket *from) {
    into->sent += from->sent;
    for (int i = 0; i < NOUT; i++) into->out[i] += from->out[i];
    if (from->nlat) {
        into->lat = xrealloc(into->lat, (into->nlat + from->nlat) * sizeof *into->lat);
        memcpy(into->lat + into->nlat, from->lat, from->nlat * sizeof *from->lat);
        into->nlat += from->nlat;
    }
}

/* `per_s`: the ok answers per second to print, or below 0 for none. */
static void print_bucket(const char *prefix, Bucket *b, double per_s) {
    if (b->nlat) qsort(b->lat, b->nlat, sizeof *b->lat, cmp_double);
    printf(" %ssent=%llu %sok=%llu %sstatus=%llu %sinvalid=%llu %sdisconnected=%llu %stimeout=%llu", prefix,
           (unsigned long long)b->sent, prefix, (unsigned long long)b->out[OK], prefix,
           (unsigned long long)b->out[STATUS], prefix, (unsigned long long)b->out[INVALID], prefix,
           (unsigned long long)b->out[DISCONNECTED], prefix, (unsigned long long)b->out[TIMEOUT]);
    if (per_s >= 0) printf(" %sok_per_s=%.0f", prefix, per_s);
    if (b->nlat) {
        size_t p50 = (b->nlat - 1) * 50 / 100, p99 = (b->nlat - 1) * 99 / 100;
        printf(" %sp50_us=%.0f %sp99_us=%.0f %smax_us=%.0f", prefix, b->lat[p50], prefix, b->lat[p99], prefix,
               b->lat[b->nlat - 1]);
    } else {
        printf(" %sp50_us=- %sp99_us=- %smax_us=-", prefix, prefix, prefix);
    }
}

static int stat_ticks(const char *path, unsigned long long *t) {
    char buf[2048];
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = 0;
    char *p = strrchr(buf, ')');
    if (!p) return -1;
    char state;
    unsigned long long utime, stime;
    /* after ")": state ppid pgrp session tty tpgid flags minflt cminflt majflt cmajflt utime stime */
    if (sscanf(p + 2, "%c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %llu %llu", &state, &utime, &stime) != 3)
        return -1;
    if (state == 'Z' || state == 'X') return -1;
    *t = utime + stime;
    return 0;
}

static int proc_cpu(pid_t pid, double *s) {
    char path[64];
    unsigned long long t;
    snprintf(path, sizeof path, "/proc/%d/stat", (int)pid);
    if (stat_ticks(path, &t) != 0) return -1;
    *s = t / (double)sysconf(_SC_CLK_TCK);
    return 0;
}

#define MAX_TASKS 1024
typedef struct {
    long tid;
    unsigned long long ticks;
} TaskCpu;

/* Each thread of PID and its CPU time so far in clock ticks, up to max; how many. */
static int proc_tasks(pid_t pid, TaskCpu *out, int max) {
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/task", (int)pid);
    DIR *d = opendir(path);
    if (!d) return 0;
    int n = 0;
    struct dirent *e;
    while (n < max && (e = readdir(d))) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        long tid = strtol(e->d_name, NULL, 10);
        char stat[96];
        snprintf(stat, sizeof stat, "/proc/%d/task/%ld/stat", (int)pid, tid);
        if (stat_ticks(stat, &out[n].ticks) == 0) out[n++].tid = tid;
    }
    closedir(d);
    return n;
}

static int by_ticks_desc(const void *a, const void *b) {
    unsigned long long x = *(const unsigned long long *)a, y = *(const unsigned long long *)b;
    return (x < y) - (x > y);
}

/* ` srv_thread_cpu_s=`: each thread's CPU time from before to after, busiest
 * first, those under 0.01 s left out (compared in whole ticks); a thread that
 * began between them counts from 0. */
static void print_task_cpu(const TaskCpu *before, int nb, const TaskCpu *after, int na) {
    unsigned long long d[MAX_TASKS], tick = (unsigned long long)sysconf(_SC_CLK_TCK);
    int n = 0;
    for (int i = 0; i < na; i++) {
        unsigned long long t0 = 0;
        for (int j = 0; j < nb; j++)
            if (before[j].tid == after[i].tid) t0 = before[j].ticks;
        if (after[i].ticks >= t0 && (after[i].ticks - t0) * 100 >= tick) d[n++] = after[i].ticks - t0;
    }
    qsort(d, n, sizeof d[0], by_ticks_desc);
    printf(" srv_thread_cpu_s=");
    if (!n) printf("-");
    for (int i = 0; i < n; i++) printf(i ? ",%.2f" : "%.2f", d[i] / (double)tick);
}

#define MAX_SOCKS 16384
#define MAX_POLLERS 512
static unsigned long listen_ino[MAX_SOCKS], est_ino[MAX_SOCKS];
static int nlisten, nest;

/* The inodes of the listening and the established TCP sockets whose local port is P. */
static void tcp_inodes(int p) {
    const char *files[] = {"/proc/net/tcp", "/proc/net/tcp6"};
    char line[512];
    nlisten = nest = 0;
    for (int i = 0; i < 2; i++) {
        FILE *f = fopen(files[i], "r");
        if (!f) continue;
        while (fgets(line, sizeof line, f)) {
            unsigned lport, st;
            unsigned long ino;
            /* sl local rem st tx:rx tr:when retrnsmt uid timeout inode */
            if (sscanf(line, " %*d: %*[0-9A-Fa-f]:%x %*[0-9A-Fa-f]:%*x %x %*x:%*x %*x:%*x %*x %*u %*u %lu", &lport,
                       &st, &ino) != 3 ||
                (int)lport != p || !ino)
                continue;
            if (st == 0x0A && nlisten < MAX_SOCKS) listen_ino[nlisten++] = ino;
            if (st == 0x01 && nest < MAX_SOCKS) est_ino[nest++] = ino;
        }
        fclose(f);
    }
}

static int has_ino(const unsigned long *set, int n, unsigned long ino) {
    for (int i = 0; i < n; i++)
        if (set[i] == ino) return 1;
    return 0;
}

static int by_int_desc(const void *a, const void *b) {
    int x = *(const int *)a, y = *(const int *)b;
    return (x < y) - (x > y);
}

/* For each epoll instance of PID that watches a listening socket on port P
 * (one per worker's reactor), how many established connections on P it
 * watches, most first, into out; how many such instances (-1 if PID's
 * descriptors could not be read). A connection is on the worker whose
 * reactor watches it. */
static int proc_pollers(pid_t pid, int p, int *out) {
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/fd", (int)pid);
    DIR *d = opendir(path);
    if (!d) return -1;
    tcp_inodes(p);
    int n = 0;
    struct dirent *e;
    while (n < MAX_POLLERS && (e = readdir(d))) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        long fd = strtol(e->d_name, NULL, 10);
        char link[96], target[64];
        snprintf(link, sizeof link, "/proc/%d/fd/%ld", (int)pid, fd);
        ssize_t len = readlink(link, target, sizeof target - 1);
        if (len < 0) continue;
        target[len] = 0;
        if (strcmp(target, "anon_inode:[eventpoll]") != 0) continue;
        snprintf(link, sizeof link, "/proc/%d/fdinfo/%ld", (int)pid, fd);
        FILE *f = fopen(link, "r");
        if (!f) continue;
        char line[256];
        int listens = 0, conns = 0;
        while (fgets(line, sizeof line, f)) {
            char *at = strstr(line, " ino:");
            if (strncmp(line, "tfd:", 4) != 0 || !at) continue;
            unsigned long ino = strtoul(at + 5, NULL, 16);
            if (has_ino(listen_ino, nlisten, ino)) listens = 1;
            if (has_ino(est_ino, nest, ino)) conns++;
        }
        fclose(f);
        if (listens) out[n++] = conns;
    }
    closedir(d);
    qsort(out, n, sizeof out[0], by_int_desc);
    return n;
}

static long proc_kib(pid_t pid, const char *field) {
    char path[64], line[256];
    snprintf(path, sizeof path, "/proc/%d/status", (int)pid);
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    long v = -1;
    size_t fl = strlen(field);
    while (fgets(line, sizeof line, f))
        if (strncmp(line, field, fl) == 0 && line[fl] == ':') v = strtol(line + fl + 1, NULL, 10);
    fclose(f);
    return v;
}

static double cpu_self(void) {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 + ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;
}

static void sleep_until(double t) {
    for (;;) {
        double d = t - now();
        if (d <= 0) return;
        struct timespec ts = {(time_t)d, (long)((d - (time_t)d) * 1e9)};
        nanosleep(&ts, NULL);
    }
}

static void quote_reasons(const char *key, Reason *r) {
    printf(" %s=", key);
    int any = 0;
    /* the four most frequent */
    int used[8] = {0};
    for (int k = 0; k < 4; k++) {
        int best = -1;
        for (int i = 0; i < 8; i++)
            if (r[i].count && !used[i] && (best < 0 || r[i].count > r[best].count)) best = i;
        if (best < 0) break;
        used[best] = 1;
        printf("%s%llu:", any ? "|" : "", (unsigned long long)r[best].count);
        for (const char *p = r[best].text; *p; p++) putchar(*p == ' ' ? '_' : *p);
        any = 1;
    }
    if (!any) printf("-");
}

int main(int argc, char **argv) {
    const char *method = "GET", *path = NULL, *body_file = NULL, *expect_file = NULL, *expect_text = NULL;
    const char *slow_path = NULL, *proto = "h1", *headers = "none", *require = NULL;
    int expect_fields = 0;
    static struct option opts[] = {
        {"port", 1, 0, 'p'},        {"proto", 1, 0, 'P'},      {"conns", 1, 0, 'c'},
        {"streams", 1, 0, 's'},     {"threads", 1, 0, 't'},    {"warmup", 1, 0, 'w'},
        {"duration", 1, 0, 'd'},    {"timeout", 1, 0, 'T'},    {"method", 1, 0, 'm'},
        {"path", 1, 0, 'u'},        {"body", 1, 0, 'b'},       {"expect", 1, 0, 'e'},
        {"expect-text", 1, 0, 'E'}, {"headers", 1, 0, 'H'},    {"require-header", 1, 0, 'R'},
        {"slow-path", 1, 0, 'S'},   {"slow-every", 1, 0, 'N'}, {"pid", 1, 0, 'k'},
        {"term-at", 1, 0, 'K'},     {"content-type", 1, 0, 'C'}, {"linger", 1, 0, 'L'},
        {"expect-fields", 0, 0, 'F'}, {"rate", 1, 0, 'r'},    {0, 0, 0, 0}};
    int o;
    while ((o = getopt_long(argc, argv, "", opts, NULL)) != -1) {
        switch (o) {
        case 'p': port = atoi(optarg); break;
        case 'P': proto = optarg; break;
        case 'c': nconns = atoi(optarg); break;
        case 's': nstreams = atoi(optarg); break;
        case 't': nthreads = atoi(optarg); break;
        case 'w': warmup_s = atof(optarg); break;
        case 'd': duration_s = atof(optarg); break;
        case 'T': timeout_s = atof(optarg) / 1000.0; break;
        case 'm': method = optarg; break;
        case 'u': path = optarg; break;
        case 'b': body_file = optarg; break;
        case 'e': expect_file = optarg; break;
        case 'E': expect_text = optarg; break;
        case 'H': headers = optarg; break;
        case 'R': require = optarg; break;
        case 'S': slow_path = optarg; break;
        case 'N': slow_every = atoi(optarg); break;
        case 'k': srv_pid = atoi(optarg); break;
        case 'K': term_at_s = atof(optarg) / 1000.0; break;
        case 'C': content_type = optarg; break;
        case 'L': linger_s = atof(optarg) / 1000.0; break;
        case 'F': expect_fields = 1; break;
        case 'r': rate = atof(optarg); break;
        default: die("unknown option");
        }
    }
    if (port <= 0 || port > 65535 || nconns <= 0 || nthreads <= 0 || nthreads > nconns || duration_s <= 0 ||
        warmup_s < 0 || !path || (!!expect_file + !!expect_text + expect_fields != 1) || nstreams <= 0 ||
        nstreams > MAXS || timeout_s <= 0 || linger_s < 0 || rate < 0)
        die("usage: see the header of bench/load/load.c");
    if (strcmp(proto, "h1") == 0)
        h2 = 0;
    else if (strcmp(proto, "h2c") == 0)
        h2 = 1;
    else
        die("--proto is h1 or h2c");
    if (!h2 && nstreams != 1) die("--streams is for h2c");
    if (strcmp(headers, "browser") == 0)
        browser = 1;
    else if (strcmp(headers, "none") != 0)
        die("--headers is none or browser");
    if (!slow_path != !slow_every) die("--slow-path and --slow-every go together");
    if (term_at_s >= 0 && !srv_pid) die("--term-at needs --pid");
    if (require) {
        const char *colon = strchr(require, ':');
        if (!colon) die("--require-header is 'name: value'");
        require_name = strndup(require, colon - require);
        require_name_len = colon - require;
        require_value = colon + 1;
        while (*require_value == ' ') require_value++;
        require_value_len = strlen(require_value);
    }
    size_t body_len = 0;
    uint8_t *body = body_file ? read_file(body_file, &body_len) : NULL;
    build(&reqs[K_MAIN], method, path, body, body_len);
    if (expect_file) {
        reqs[K_MAIN].expect = read_file(expect_file, &reqs[K_MAIN].expect_len);
    } else if (expect_fields) {
        if (body) die("--expect-fields is for a request without a body");
        reqs[K_MAIN].expect = fields_echo(&reqs[K_MAIN].expect_len);
    } else {
        reqs[K_MAIN].expect = (const uint8_t *)expect_text;
        reqs[K_MAIN].expect_len = strlen(expect_text);
    }
    if (slow_path) {
        build(&reqs[K_SLOW], "GET", slow_path, NULL, 0);
        reqs[K_SLOW].expect = (const uint8_t *)"slow";
        reqs[K_SLOW].expect_len = 4;
    }
    signal(SIGPIPE, SIG_IGN);
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < rl.rlim_max) {
        rl.rlim_cur = rl.rlim_max;
        setrlimit(RLIMIT_NOFILE, &rl);
    }

    Worker *ws = calloc(nthreads, sizeof *ws);
    Conn *conns = calloc(nconns, sizeof *conns);
    if (!ws || !conns) die("out of memory");
    t0 = now();
    for (int i = 0, at = 0; i < nthreads; i++) {
        ws[i].id = i;
        ws[i].nconn = nconns / nthreads + (i < nconns % nthreads);
        ws[i].conns = conns + at;
        at += ws[i].nconn;
        if (pthread_create(&ws[i].thread, NULL, run, &ws[i])) die("pthread_create");
    }
    double cpu0 = 0, cpu1 = 0, cli0, cli1, exit_ms = -1;
    int have_cpu = 0;
    static TaskCpu tasks0[MAX_TASKS], tasks1[MAX_TASKS];
    int ntasks0 = 0, ntasks1 = 0;
    sleep_until(t0 + warmup_s);
    cli0 = cpu_self();
    if (srv_pid && proc_cpu(srv_pid, &cpu0) == 0) have_cpu = 1;
    if (have_cpu) ntasks0 = proc_tasks(srv_pid, tasks0, MAX_TASKS);
    static int pollers[MAX_POLLERS];
    int npollers = srv_pid ? proc_pollers(srv_pid, port, pollers) : -1;
    long rss_peak = -1, rss = -1;
    if (term_at_s >= 0) {
        sleep_until(t0 + warmup_s + term_at_s);
        t_signal = now();
        __atomic_store_n(&signalled, 1, __ATOMIC_RELEASE);
        if (have_cpu) ntasks1 = proc_tasks(srv_pid, tasks1, MAX_TASKS);
        if (have_cpu && proc_cpu(srv_pid, &cpu1) != 0) have_cpu = 0;
        rss_peak = proc_kib(srv_pid, "VmHWM");
        rss = proc_kib(srv_pid, "VmRSS");
        kill(srv_pid, SIGTERM);
        double end = t0 + warmup_s + duration_s;
        while (now() < end) {
            double x;
            if (proc_cpu(srv_pid, &x) != 0) {
                exit_ms = (now() - t_signal) * 1000;
                break;
            }
            struct timespec ts = {0, 2000000};
            nanosleep(&ts, NULL);
        }
    } else {
        sleep_until(t0 + warmup_s + duration_s);
        if (have_cpu) ntasks1 = proc_tasks(srv_pid, tasks1, MAX_TASKS);
        if (have_cpu && proc_cpu(srv_pid, &cpu1) != 0) have_cpu = 0;
        if (srv_pid) {
            rss_peak = proc_kib(srv_pid, "VmHWM");
            rss = proc_kib(srv_pid, "VmRSS");
        }
    }
    cli1 = cpu_self();
    for (int i = 0; i < nthreads; i++) pthread_join(ws[i].thread, NULL);
    if (term_at_s >= 0 && exit_ms < 0) {
        double x;
        if (proc_cpu(srv_pid, &x) != 0) exit_ms = (now() - t_signal) * 1000; /* ended while draining */
    }

    Bucket total[NG][NK];
    memset(total, 0, sizeof total);
    Stats all;
    memset(&all, 0, sizeof all);
    double cli_thread_max = 0;
    for (int i = 0; i < nthreads; i++) {
        for (int g = 0; g < NG; g++)
            for (int k = 0; k < NK; k++) merge(&total[g][k], &ws[i].stats.b[g][k]);
        all.connects += ws[i].stats.connects;
        all.connect_failed += ws[i].stats.connect_failed;
        all.after_connect_failed += ws[i].stats.after_connect_failed;
        for (int k = 0; k < NK; k++) all.ok_in_window[k] += ws[i].stats.ok_in_window[k];
        all.inflight_end += ws[i].stats.inflight_end;
        all.ok_late += ws[i].stats.ok_late;
        all.queued += ws[i].stats.queued;
        all.unsent += ws[i].stats.unsent;
        if (ws[i].stats.nlag) {
            all.lag = xrealloc(all.lag, (all.nlag + ws[i].stats.nlag) * sizeof *all.lag);
            memcpy(all.lag + all.nlag, ws[i].stats.lag, ws[i].stats.nlag * sizeof *all.lag);
            all.nlag += ws[i].stats.nlag;
        }
        if (ws[i].cpu_s > cli_thread_max) cli_thread_max = ws[i].cpu_s;
        all.stray += ws[i].stats.stray;
        all.after_end += ws[i].stats.after_end;
        all.conn_errors += ws[i].stats.conn_errors;
        for (int which = 0; which < 4; which++)
            for (int r = 0; r < 8; r++) {
                Reason *x = &ws[i].stats.why[which][r];
                for (uint64_t c = 0; c < x->count; c++) reason(&all, which, x->text);
            }
    }
    printf("proto=%s conns=%d streams=%d", proto, nconns, nstreams);
    print_bucket("", &total[G_MEAS][K_MAIN], all.ok_in_window[K_MAIN] / duration_s);
    printf(" inflight_end=%llu ok_late=%llu", (unsigned long long)all.inflight_end,
           (unsigned long long)all.ok_late);
    if (rate) {
        printf(" rate=%g queued=%llu unsent=%llu", rate, (unsigned long long)all.queued,
               (unsigned long long)all.unsent);
        if (all.nlag) {
            qsort(all.lag, all.nlag, sizeof *all.lag, cmp_double);
            printf(" send_lag_p99_us=%.0f send_lag_max_us=%.0f", all.lag[(all.nlag - 1) * 99 / 100],
                   all.lag[all.nlag - 1]);
        } else {
            printf(" send_lag_p99_us=- send_lag_max_us=-");
        }
    }
    if (slow_path) print_bucket("slow_", &total[G_MEAS][K_SLOW], -1);
    if (term_at_s >= 0) {
        merge(&total[G_AFTER][K_MAIN], &total[G_AFTER][K_SLOW]);
        print_bucket("after_", &total[G_AFTER][K_MAIN], -1);
        printf(" after_connect_failed=%llu", (unsigned long long)all.after_connect_failed);
        if (exit_ms >= 0)
            printf(" exit_ms=%.0f", exit_ms);
        else
            printf(" exit_ms=-");
    }
    uint64_t warm_bad = 0;
    for (int k = 0; k < NK; k++) warm_bad += total[G_WARM][k].sent - total[G_WARM][k].out[OK];
    printf(" warmup_bad=%llu", (unsigned long long)warm_bad);
    /* the same window as the CPU time: the ok answers that ended in it */
    uint64_t ok = all.ok_in_window[K_MAIN] + all.ok_in_window[K_SLOW];
    if (have_cpu && term_at_s < 0) {
        double window = cpu1 - cpu0;
        printf(" srv_cpu_s=%.2f srv_cpu_us_per_ok=%s", window, "");
        if (ok)
            printf("%.2f", window * 1e6 / ok);
        else
            printf("-");
    } else if (have_cpu) { /* stop: the CPU time ends at the signal */
        printf(" srv_cpu_s=%.2f srv_cpu_us_per_ok=-", cpu1 - cpu0);
    } else {
        printf(" srv_cpu_s=- srv_cpu_us_per_ok=-");
    }
    if (have_cpu)
        print_task_cpu(tasks0, ntasks0, tasks1, ntasks1);
    else
        printf(" srv_thread_cpu_s=-");
    printf(" srv_conns_by_poller=");
    if (npollers <= 0) printf("-");
    for (int i = 0; i < npollers; i++) printf(i ? ",%d" : "%d", pollers[i]);
    printf(" srv_rss_peak_kib=");
    rss_peak >= 0 ? printf("%ld", rss_peak) : printf("-");
    printf(" srv_rss_kib=");
    rss >= 0 ? printf("%ld", rss) : printf("-");
    printf(" cli_cpu_s=%.2f cli_thread_cpu_max_s=%.2f connects=%llu connect_failed=%llu stray=%llu after_end=%llu conn_errors=%llu",
           cli1 - cli0, cli_thread_max, (unsigned long long)all.connects, (unsigned long long)all.connect_failed,
           (unsigned long long)all.stray, (unsigned long long)all.after_end, (unsigned long long)all.conn_errors);
    quote_reasons("invalid_as", all.why[0]);
    quote_reasons("disconnected_as", all.why[1]);
    quote_reasons("status_as", all.why[2]);
    quote_reasons("conn_errors_as", all.why[3]);
    printf("\n");
    return 0;
}
