"""HTTP/1.1 client for scripts/bench_headers.sh: PORT SECONDS.

For each header shape, against the server on 127.0.0.1:PORT:
- `single`: one request at a time on a new connection, 200 times for
  `browser12` and 5 times otherwise; the median and minimum in ms;
- `load` (not for `browser12`): four connections each send the shape one
  request after another for SECONDS while a fifth sends a bare `GET /`
  every 10 ms; the heavy requests answered per second and the bare
  requests' latency percentiles in ms.
Every answer must be 200. Shapes are the largest Flare v0.12.0 admits over
HTTP/1.1 (`max_header_size` 8192 counts header lines without CRLF):
`same4000` (4000 lines `a:`) and `distinct2600` (2600 lines, each a
distinct two-byte name and no value)."""

import itertools
import socket
import string
import sys
import threading
import time

port, seconds = int(sys.argv[1]), float(sys.argv[2])
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
    closed the keep-alive connection."""
    while True:
        if conn[0] is None:
            conn[0] = socket.create_connection(("127.0.0.1", port))
            conn[1] = b""
        try:
            status, conn[1] = roundtrip(conn[0], data, conn[1])
        except (EOFError, ConnectionResetError, BrokenPipeError):
            conn[0].close()
            conn[0] = None
            continue
        if status != "200":
            raise SystemExit(f"status {status}")
        return


def single(name):
    data = request(SHAPES[name])
    times = []
    for _ in range(200 if name == "browser12" else 5):
        conn = [None, b""]
        start = time.perf_counter()
        call(conn, data)
        times.append((time.perf_counter() - start) * 1000)
        conn[0].close()
    times.sort()
    print(f"{name}\tsingle\tbytes={len(data)}\tmedian_ms={times[len(times) // 2]:.3f}\tmin_ms={times[0]:.3f}")


def load(name):
    data = request(SHAPES[name])
    stop = time.perf_counter() + seconds
    answered = [0] * 4
    latency = []

    def heavy(j):
        conn = [None, b""]
        while time.perf_counter() < stop:
            call(conn, data)
            answered[j] += 1

    def bare():
        conn = [None, b""]
        while time.perf_counter() < stop:
            start = time.perf_counter()
            call(conn, BARE)
            latency.append((time.perf_counter() - start) * 1000)
            time.sleep(0.01)

    threads = [threading.Thread(target=heavy, args=(j,)) for j in range(4)]
    threads.append(threading.Thread(target=bare))
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    latency.sort()
    pct = lambda p: latency[min(len(latency) - 1, int(p * len(latency)))]
    print(f"{name}\tload\theavy_per_s={sum(answered) / seconds:.1f}\tbare_n={len(latency)}\tbare_p50_ms={pct(0.5):.2f}\tbare_p99_ms={pct(0.99):.2f}\tbare_max_ms={latency[-1]:.2f}")


for shape in SHAPES:
    single(shape)
for shape in ("same4000", "distinct2600"):
    load(shape)
