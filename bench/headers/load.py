"""HTTP/1.1 client for scripts/bench_headers.sh: PORT SECONDS.

For each header shape, against the server on 127.0.0.1:PORT:
- `single`: one request at a time on a new connection, 200 times for
  `browser12` and 5 times otherwise; the median and minimum in ms;
- `load` (not for `browser12`): four connections each send the shape one
  request after another for SECONDS while a fifth sends a bare `GET /`,
  waits for its answer and sleeps 10 ms before the next, a closed loop, so
  the slower the bare answers, the fewer are sent (`bare_n`, beside the
  percentiles; with few samples p99 is about the maximum); the heavy
  requests answered per second and the bare requests' latency percentiles
  in ms.
Every answer must be 200, and no connect, send or receive may wait more
than TIMEOUT_S; otherwise the run stops with an error, also when it
happens on a `load` connection. When the server has closed a kept-open
connection, the request is sent again on a new one, at most RETRIES times
in a row; each line prints how many requests were sent again (`resent`),
so the server may have received up to that many more requests than were
answered. Shapes are the largest Flare v0.12.0 admits over HTTP/1.1 (`max_header_size` 8192 counts header lines without CRLF):
`same4000` (4000 lines `a:`) and `distinct2600` (2600 lines, each a
distinct two-byte name and no value)."""

import itertools
import socket
import string
import sys
import threading
import time

port, seconds = int(sys.argv[1]), float(sys.argv[2])
TIMEOUT_S = 30.0
RETRIES = 3
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
    "same4000": "a:\r\n" * 4000,
    "distinct2600": "".join(f"{n}:\r\n" for n in TWO[:2600]),
}


class Failed(Exception):
    """A request that did not get its 200."""


def request(fields):
    return ("GET / HTTP/1.1\r\nHost: x\r\n" + fields + "\r\n").encode()


BARE = request("")


def roundtrip(sock, data, buf):
    """Sends `data`, reads one answer; returns its status and what follows."""
    sock.sendall(data)
    while True:
        end = buf.find(b"\r\n\r\n")
        if end >= 0:
            head = buf[:end].decode()
            length = 0
            for line in head.split("\r\n")[1:]:
                if line.lower().startswith("content-length:"):
                    length = int(line.split(":", 1)[1])
            if len(buf) >= end + 4 + length:
                return head.split(" ")[1], buf[end + 4 + length:]
        chunk = sock.recv(65536)
        if not chunk:
            raise EOFError
        buf += chunk


def call(conn, data):
    """One answer on `conn` ([socket, buffer]), reconnecting when Flare has
    closed the keep-alive connection; returns how many times the request
    was sent again."""
    resent = 0
    while True:
        try:
            if conn[0] is None:
                conn[1] = b""
                conn[0] = socket.create_connection(("127.0.0.1", port), TIMEOUT_S)
            status, conn[1] = roundtrip(conn[0], data, conn[1])
        except socket.timeout:
            raise Failed(f"a socket operation waited over {TIMEOUT_S} s")
        except (EOFError, ConnectionResetError, BrokenPipeError):
            if conn[0] is not None:
                conn[0].close()
            conn[0] = None
            resent += 1
            if resent > RETRIES:
                raise Failed(f"connection closed {resent} times in a row")
            continue
        except OSError as e:
            raise Failed(f"socket error: {e}")
        if status != "200":
            raise Failed(f"status {status}")
        return resent


def single(name):
    data = request(SHAPES[name])
    times = []
    resent = 0
    for _ in range(200 if name == "browser12" else 5):
        conn = [None, b""]
        start = time.perf_counter()
        resent += call(conn, data)
        times.append((time.perf_counter() - start) * 1000)
        conn[0].close()
    times.sort()
    print(f"{name}\tsingle\tbytes={len(data)}\tmedian_ms={times[len(times) // 2]:.3f}\tmin_ms={times[0]:.3f}\tresent={resent}")


def load(name):
    data = request(SHAPES[name])
    stop = time.perf_counter() + seconds
    answered = [0] * 4
    resent = [0] * 5
    latency = []
    errors = []

    def heavy(j):
        conn = [None, b""]
        try:
            while time.perf_counter() < stop and not errors:
                resent[j] += call(conn, data)
                answered[j] += 1
        except Failed as e:
            errors.append(str(e))

    def bare():
        conn = [None, b""]
        try:
            while time.perf_counter() < stop and not errors:
                start = time.perf_counter()
                resent[4] += call(conn, BARE)
                latency.append((time.perf_counter() - start) * 1000)
                time.sleep(0.01)
        except Failed as e:
            errors.append(str(e))

    threads = [threading.Thread(target=heavy, args=(j,)) for j in range(4)]
    threads.append(threading.Thread(target=bare))
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if errors:
        raise Failed(f"{name} load: {errors[0]}")
    latency.sort()
    pct = lambda p: latency[min(len(latency) - 1, int(p * len(latency)))]
    print(f"{name}\tload\theavy_per_s={sum(answered) / seconds:.1f}\tbare_n={len(latency)}\tbare_p50_ms={pct(0.5):.2f}\tbare_p99_ms={pct(0.99):.2f}\tbare_max_ms={latency[-1]:.2f}\tresent={sum(resent)}")


try:
    for shape in SHAPES:
        single(shape)
    for shape in ("same4000", "distinct2600"):
        load(shape)
except Failed as e:
    raise SystemExit(str(e))
