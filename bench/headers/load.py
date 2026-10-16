"""HTTP/1.1 client for scripts/bench_headers.sh: PORT SECONDS, or `--cases`
to list the cases a run prints (`CASES`).

For each header shape, against the server on 127.0.0.1:PORT:
- `single`: one request at a time on a new connection, 200 times for
  `browser12`, `distinct100` and `distinct256` and 5 times otherwise; the
  median and minimum in ms;
- `rate` (`browser12`, `distinct100` and `distinct256`, within a field
  limit of 100 or 256): a request due every 1/RATE s whatever the
  answers, each on a new connection of its own, for SECONDS; latency
  counted from when it was due, its percentiles in ms and, as `start`, how
  late each request's thread began (see `open`). The same arrivals for
  every server, so their percentiles compare;
- `load` (`same4000` and `distinct2600`): four connections each send the shape one
  request after another for SECONDS while a fifth sends a bare `GET /`,
  waits for its answer and sleeps 10 ms before the next. A closed loop:
  the slower the bare answers, the fewer are sent (`bare_n`; with few
  samples p99 is about the maximum), so two servers' bare latencies are
  not measured under the same arrivals. Prints the heavy requests answered
  per second and the bare requests' latency percentiles in ms;
- `open` (not for `browser12`): the same four connections, while a bare
  `GET /` is due every 10 ms whatever the answers, each on a new
  connection of its own; its latency is counted from when it was due, so
  a send that starts late counts its delay. An open loop: the same arrivals
  for every server, `open_n` of them. Prints the heavy requests answered
  per second, the bare requests' latency percentiles in ms and, as
  `start`, how late each request's thread began (Python's thread start
  and scheduling, part of the latency but not the server's).
`browser12`, `distinct100` and `distinct256` ask `GET /read`, whose
handler looks up 10 names and walks every field (bench/headers/
muntin_server.mojo); the others ask `GET /`.
Every answer must be `HTTP/1.1 200` with a well-formed head, and each
request, its connects, sends and receives together (a resend included),
must end within TIMEOUT_S of its start. Anything else, an unexpected exception on any thread
included, stops the run with exit status 1 after printing each failure
(with its traceback). When the server has closed a kept-open connection,
the request is sent again on a new one, at most RETRIES times in a row;
each line prints how many requests were sent again (`resent`), so the
server may have received up to that many more requests than were
answered. `distinctN` is N fields, as many as a limit of N admits: `Host`
(every request's) and N - 1 lines `x-hNNNN: v`, each its own name, as
bench/headers/bench_headers.mojo's; `same4000` and `distinct2600` are the
largest shapes Flare v0.12.0 admits over HTTP/1.1 (`max_header_size` 8192
counts header lines without CRLF): 4000 lines `a:`, and 2600 lines, each a
distinct two-byte name and no value."""

import itertools
import re
import socket
import string
import sys
import threading
import time
import traceback

TIMEOUT_S = 30.0
RETRIES = 3
RATE = 200
TOKENS = string.ascii_lowercase + string.digits + "!#$%&'*+-.^_`|~"
TWO = ["".join(p) for p in itertools.product(TOKENS, repeat=2)]
BROWSER = [
    ("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"),
    ("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
    ("Accept-Language", "ja,en-US;q=0.9,en;q=0.8"),
    ("Accept-Encoding", "gzip, deflate, br, zstd"),
    ("Connection", "keep-alive"),
    ("Cookie", "session=abc123; theme=dark"),
    ("Cookie", "lang=ja"),
    ("Upgrade-Insecure-Requests", "1"),
    ("Sec-Fetch-Dest", "document"),
    ("Sec-Fetch-Mode", "navigate"),
    ("Sec-Fetch-Site", "none"),
]
SHAPES = {
    "browser12": "".join(f"{k}: {v}\r\n" for k, v in BROWSER),
    "distinct100": "".join(f"x-h{i:04}: v\r\n" for i in range(99)),
    "distinct256": "".join(f"x-h{i:04}: v\r\n" for i in range(255)),
    "same4000": "a:\r\n" * 4000,
    "distinct2600": "".join(f"{n}:\r\n" for n in TWO[:2600]),
}


class Failed(Exception):
    """A request that did not get its 200."""


BOUNDED = ("browser12", "distinct100", "distinct256")
HEAVY = ("same4000", "distinct2600")
CASES = (
    [(s, "single") for s in SHAPES]
    + [(s, "rate") for s in BOUNDED]
    + [(s, k) for s in HEAVY for k in ("load", "open")]
)
"""Every (shape, kind) a run prints, in order; `load.py --cases` lists them
for bench/headers/median.py."""


def request(fields, path="/"):
    return (f"GET {path} HTTP/1.1\r\nHost: x\r\n" + fields + "\r\n").encode()


def shaped(name):
    return request(SHAPES[name], "/read" if name in BOUNDED else "/")


BARE = request("")
INTERVAL_S = 0.01


STATUS_LINE = re.compile(r"HTTP/1\.1 ([0-9]{3}) [^\r\n]*")
FIELD_LINE = re.compile(r"[!#$%&'*+\-.^_`|~0-9A-Za-z]+:[^\r\n]*")


def settle(sock, deadline):
    """Bounds the next socket operation by what is left before `deadline`."""
    left = deadline - time.monotonic()
    if left <= 0:
        raise socket.timeout
    sock.settimeout(left)


def parse_head(head):
    """The status and Content-Length of an answer head, or Failed."""
    try:
        lines = head.decode("ascii").split("\r\n")
    except UnicodeDecodeError as e:
        raise Failed(f"malformed answer head: {e!r}")
    m = STATUS_LINE.fullmatch(lines[0])
    if not m:
        raise Failed(f"malformed status line: {lines[0]!r}")
    lengths = []
    for line in lines[1:]:
        if not FIELD_LINE.fullmatch(line):
            raise Failed(f"malformed field line: {line!r}")
        name, value = line.split(":", 1)
        if name.lower() == "transfer-encoding":
            raise Failed("chunked answers are not expected")
        if name.lower() == "content-length":
            if not value.strip().isdigit():
                raise Failed(f"malformed Content-Length: {value!r}")
            lengths.append(int(value))
    # Flare frames every answer here with one Content-Length; anything else
    # would leave where the next answer starts unknown.
    if len(lengths) != 1:
        raise Failed(f"expected one Content-Length, got {lengths}")
    return m.group(1), lengths[0]


def roundtrip(sock, data, buf, deadline):
    """Sends `data`, reads one answer by `deadline`; returns its status and
    what follows it."""
    settle(sock, deadline)
    sock.sendall(data)
    while True:
        end = buf.find(b"\r\n\r\n")
        if end >= 0:
            status, length = parse_head(buf[:end])
            if len(buf) >= end + 4 + length:
                return status, buf[end + 4 + length:]
        settle(sock, deadline)
        chunk = sock.recv(65536)
        if not chunk:
            raise EOFError
        buf += chunk


def close(conn):
    if conn[0] is not None:
        conn[0].close()
        conn[0] = None


def call(conn, data):
    """One answer on `conn` ([socket, buffer]), reconnecting when Flare has
    closed the keep-alive connection; returns how many times the request
    was sent again."""
    resent = 0
    deadline = time.monotonic() + TIMEOUT_S
    while True:
        try:
            if conn[0] is None:
                conn[1] = b""
                left = deadline - time.monotonic()
                if left <= 0:
                    raise socket.timeout
                conn[0] = socket.create_connection(("127.0.0.1", port), left)
            status, conn[1] = roundtrip(conn[0], data, conn[1], deadline)
        except socket.timeout:
            raise Failed(f"a request took over {TIMEOUT_S} s")
        except (EOFError, ConnectionResetError, BrokenPipeError):
            close(conn)
            resent += 1
            if resent > RETRIES:
                raise Failed(f"connection closed {resent} times in a row")
            continue
        except OSError as e:
            raise Failed(f"socket error: {e}")
        if status != "200":
            raise Failed(f"status {status}")
        return resent


def guarded(f, failures):
    """Runs `f`; any exception it raises is appended to `failures` with its
    traceback, so a thread never ends unnoticed."""
    try:
        f()
    except BaseException:
        failures.append(traceback.format_exc())


def spawn(f, failures):
    t = threading.Thread(target=guarded, args=(f, failures))
    t.start()
    return t


def run_threads(targets, failures):
    """Runs every target on its own thread and joins them; the targets see
    `failures` and stop once it is not empty."""
    for t in [spawn(f, failures) for f in targets]:
        t.join()


def percentiles(prefix, latency):
    latency.sort()
    pct = lambda p: latency[min(len(latency) - 1, int(p * len(latency)))]
    return f"{prefix}_n={len(latency)}\t{prefix}_p50_ms={pct(0.5):.2f}\t{prefix}_p95_ms={pct(0.95):.2f}\t{prefix}_p99_ms={pct(0.99):.2f}\t{prefix}_max_ms={latency[-1]:.2f}"


def single(name):
    data = shaped(name)
    times = []
    resent = 0
    for _ in range(200 if name in BOUNDED else 5):
        conn = [None, b""]
        try:
            start = time.perf_counter()
            resent += call(conn, data)
            times.append((time.perf_counter() - start) * 1000)
        finally:
            close(conn)
    times.sort()
    print(f"{name}\tsingle\tbytes={len(data)}\tmedian_ms={times[len(times) // 2]:.3f}\tmin_ms={times[0]:.3f}\tresent={resent}")


def heavy_senders(data, stop, answered, resent, failures):
    def heavy(j):
        conn = [None, b""]
        try:
            while time.perf_counter() < stop and not failures:
                resent[j] += call(conn, data)
                answered[j] += 1
        finally:
            close(conn)

    return [lambda j=j: heavy(j) for j in range(4)]


def load(name, failures):
    data = shaped(name)
    stop = time.perf_counter() + seconds
    answered = [0] * 4
    resent = [0] * 5
    latency = []

    def bare():
        conn = [None, b""]
        try:
            while time.perf_counter() < stop and not failures:
                start = time.perf_counter()
                resent[4] += call(conn, BARE)
                latency.append((time.perf_counter() - start) * 1000)
                time.sleep(INTERVAL_S)
        finally:
            close(conn)

    run_threads(heavy_senders(data, stop, answered, resent, failures) + [bare], failures)
    if failures:
        return
    if not latency:
        failures.append(f"{name} load: no bare answer")
        return
    print(f"{name}\tload\theavy_per_s={sum(answered) / seconds:.1f}\t{percentiles('bare', latency)}\tresent={sum(resent)}")


def arrivals(data, interval, resent, latency, lag, failures):
    """A sender of `data` due every `interval` s from now for SECONDS, each
    on a new connection and thread, with `latency` counted from when it was
    due and `lag` how late its thread began; and the number due."""
    begin = time.perf_counter()
    due = [begin + k * interval for k in range(int(seconds / interval))]

    def one(t):
        lag.append((time.perf_counter() - t) * 1000)
        conn = [None, b""]
        try:
            # list.append is atomic; `+=` on a shared cell is not.
            resent.append(call(conn, data))
            latency.append((time.perf_counter() - t) * 1000)
        finally:
            close(conn)

    def send():
        threads = []
        for t in due:
            if failures:
                break
            wait = t - time.perf_counter()
            if wait > 0:
                time.sleep(wait)
            threads.append(spawn(lambda t=t: one(t), failures))
        for th in threads:
            th.join()

    return send, len(due)


def open_loop(name, failures):
    data = shaped(name)
    stop = time.perf_counter() + seconds
    answered = [0] * 4
    resent = [0] * 4
    bare_resent = []
    latency = []
    lag = []
    bare, due = arrivals(BARE, INTERVAL_S, bare_resent, latency, lag, failures)
    run_threads(heavy_senders(data, stop, answered, resent, failures) + [bare], failures)
    if failures:
        return
    if len(latency) != due:
        failures.append(f"{name} open: {len(latency)} of {due} bare requests answered")
        return
    print(f"{name}\topen\theavy_per_s={sum(answered) / seconds:.1f}\t{percentiles('open', latency)}\t{percentiles('start', lag)}\tresent={sum(resent) + sum(bare_resent)}")


def rate(name, failures):
    resent = []
    latency = []
    lag = []
    send, due = arrivals(shaped(name), 1 / RATE, resent, latency, lag, failures)
    run_threads([send], failures)
    if failures:
        return
    if len(latency) != due:
        failures.append(f"{name} rate: {len(latency)} of {due} requests answered")
        return
    print(f"{name}\trate\tper_s={RATE}\t{percentiles('rate', latency)}\t{percentiles('start', lag)}\tresent={sum(resent)}")


if sys.argv[1:] == ["--cases"]:
    for shape, kind in CASES:
        print(f"{shape}\t{kind}")
    raise SystemExit(0)
port, seconds = int(sys.argv[1]), float(sys.argv[2])
RUN = {"single": lambda shape, _: single(shape), "rate": rate, "load": load, "open": open_loop}
failures = []
try:
    for shape, kind in CASES:
        RUN[kind](shape, failures)
        if failures:
            break
except Failed as e:
    failures.append(str(e))
if failures:
    for f in failures:
        print(f, file=sys.stderr)
    raise SystemExit(1)
