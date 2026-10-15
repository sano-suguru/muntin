"""The head-of-line blocking measurement's client (Python standard library
only). Not part of Muntin and not run by CI; scripts/bench_hol.sh runs it.

    python3 hol_client.py PORT MODE SLOW_MS

One run against a fresh server on 127.0.0.1:PORT (bench/hol/hol_muntin.mojo
or hol_flare.mojo). It opens the connections MODE needs and answers one
`/health` on each, so every one is accepted and idle when the hold starts.
At `HOLD_AT_S` it sends one `GET /slow/SLOW_MS`, whose handler blocks its
serving thread for SLOW_MS. From the start to `HOLD_AT_S + SLOW_MS +
TAIL_S` it sends `GET /health` every `PERIOD_S`, each from its own thread, and
records for each probe when it was sent and whether and when it was
answered. A probe with no answer `ANSWER_BOUND_S` after the hold ended is
lost, as is one whose connection was closed or reset first.

MODE is where the probes go:
- `h1-new`: each probe on a new HTTP/1.1 connection (`Connection: close`),
  the slow request on its own.
- `h1-pool`: a keep-alive pool of `POOL` HTTP/1.1 connections, opened and
  answered before the hold; a probe takes an idle connection from it (a new
  one when none is idle, as a client's pool does) and puts it back once
  answered. The slow request is on its own connection.
- `h2c-same`: prior-knowledge h2c; the slow request is stream 1 of the
  connection every probe is a later stream of.
- `h2c-other`: as `h2c-same`, with the slow request on a second h2c
  connection.
- `spread`: no slow request; how a server spreads long-lived connections over
  its workers (`spread` below says how), printed as `spread
  sequential=<connections per worker> burst=<...>`, e.g. `16` for one worker.

It prints one line, `MODE n=<probes sent during the hold> prompt=<answered
within PROMPT_S> delayed=<answered later> lost=<not answered>
p50_ms=<median latency of the answered> max_ms=<largest> slow=<the slow
request's outcome>`, counting only the probes sent while the slow handler
ran (from the moment it was sent to SLOW_MS later): those are what the hold
can affect.
"""

import socket
import struct
import sys
import threading
import time

HOLD_AT_S = 0.3
PERIOD_S = 0.05
TAIL_S = 0.7
PROMPT_S = 0.1
ANSWER_BOUND_S = 3.0
POOL = 8
SPREAD = 16


def h1_request(path, close):
    extra = "Connection: close\r\n" if close else ""
    return f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n{extra}\r\n".encode()


def h1_read_response(sock, with_body=False):
    """The status of one response that declares its Content-Length (its body
    with `with_body`); raises on EOF."""
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    head, _, body = data.partition(b"\r\n\r\n")
    length = 0
    for line in head.split(b"\r\n")[1:]:
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            length = int(value.strip())
    while len(body) < length:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("closed")
        body += chunk
    return int(head.split(b" ")[1]) if not with_body else body


def h1_connect(port):
    sock = socket.create_connection(("127.0.0.1", port))
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return sock


class H2c:
    """A minimal prior-knowledge h2c client: GET only, responses small enough
    for the default windows, HPACK literals without Huffman coding."""

    def __init__(self, port):
        self.port = port
        self.sock = h1_connect(port)
        self.lock = threading.Lock()
        self.next_id = 1
        self.waiting = {}  # stream id -> [event, status or error]
        self.dead = None
        self.sock.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + self.frame(4, 0, 0, b""))
        threading.Thread(target=self.read_loop, daemon=True).start()

    @staticmethod
    def frame(kind, flags, stream, payload):
        return struct.pack(">I", len(payload))[1:] + bytes([kind, flags]) + struct.pack(">I", stream) + payload

    def get(self, path):
        """Sends a GET and returns (event, slot): slot[1] is set before event."""
        authority = f"127.0.0.1:{self.port}".encode()
        block = b"\x82\x86\x04" + bytes([len(path)]) + path.encode() + b"\x01" + bytes([len(authority)]) + authority
        with self.lock:
            stream = self.next_id
            self.next_id += 2
            slot = [threading.Event(), None]
            self.waiting[stream] = slot
            if self.dead is not None:
                slot[1] = self.dead
                slot[0].set()
                return slot
            try:
                self.sock.sendall(self.frame(1, 0x5, stream, block))
            except OSError as e:
                del self.waiting[stream]
                slot[1] = str(e) or type(e).__name__
                slot[0].set()
        return slot

    def recv_exact(self, n):
        data = b""
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("closed")
            data += chunk
        return data

    def read_loop(self):
        try:
            while True:
                head = self.recv_exact(9)
                length = struct.unpack(">I", b"\x00" + head[:3])[0]
                kind, flags = head[3], head[4]
                stream = struct.unpack(">I", head[5:9])[0] & 0x7FFFFFFF
                payload = self.recv_exact(length)
                if kind == 4 and not flags & 1:  # SETTINGS
                    with self.lock:
                        self.sock.sendall(self.frame(4, 1, 0, b""))
                elif kind == 6 and not flags & 1:  # PING
                    with self.lock:
                        self.sock.sendall(self.frame(6, 1, 0, payload))
                elif kind == 1:  # HEADERS: the first field is :status
                    with self.lock:
                        slot = self.waiting.get(stream)
                    if slot is not None:
                        slot.append(self.status(payload))
                if kind in (0, 1) and flags & 1:  # END_STREAM
                    with self.lock:
                        slot = self.waiting.pop(stream, None)
                    if slot is not None:
                        slot[1] = slot[2] if len(slot) > 2 else "no status"
                        slot[0].set()
                elif kind == 3:  # RST_STREAM
                    self.fail_stream(stream, "reset")
                elif kind == 7:  # GOAWAY
                    raise ConnectionError("goaway")
        except (OSError, ConnectionError) as e:
            self.fail_all(type(e).__name__ if not str(e) else str(e))

    @staticmethod
    def status(block):
        """The :status of a header block whose first field is it: indexed
        (static entries 8 to 14) or a literal with an indexed name and a value
        without Huffman coding, as Flare v0.12.0 sends it."""
        first = block[0]
        if first & 0x80:
            return {8: 200, 9: 204, 10: 206, 11: 304, 12: 400, 13: 404, 14: 500}.get(first & 0x7F, "status?")
        if block[1] & 0x80:
            return "status?"
        return int(block[2 : 2 + block[1]])

    def fail_stream(self, stream, reason):
        with self.lock:
            slot = self.waiting.pop(stream, None)
        if slot is not None:
            slot[1] = reason
            slot[0].set()

    def fail_all(self, reason):
        with self.lock:
            self.dead = reason
            slots = list(self.waiting.values())
            self.waiting.clear()
        for slot in slots:
            slot[1] = reason
            slot[0].set()

    def call(self, path, timeout):
        slot = self.get(path)
        if not slot[0].wait(timeout):
            return "timeout"
        return slot[1]


class Pool:
    def __init__(self, port):
        self.port = port
        self.lock = threading.Lock()
        self.idle = [h1_connect(port) for _ in range(POOL)]
        for sock in self.idle:
            sock.sendall(h1_request("/health", False))
            h1_read_response(sock)

    def call(self, path, timeout):
        with self.lock:
            sock = self.idle.pop(0) if self.idle else None
        if sock is None:
            sock = h1_connect(self.port)
        sock.settimeout(timeout)
        try:
            sock.sendall(h1_request(path, False))
            status = h1_read_response(sock)
        except OSError as e:
            sock.close()
            return "timeout" if isinstance(e, socket.timeout) else type(e).__name__
        except ConnectionError as e:
            sock.close()
            return str(e)
        with self.lock:
            self.idle.append(sock)
        return status


def h1_new_call(port, path, timeout):
    try:
        sock = h1_connect(port)
        sock.settimeout(timeout)
        sock.sendall(h1_request(path, True))
        status = h1_read_response(sock)
        sock.close()
        return status
    except socket.timeout:
        return "timeout"
    except (OSError, ConnectionError) as e:
        return str(e) or type(e).__name__


def spread(port):
    """Opens `SPREAD` keep-alive HTTP/1.1 connections one after another, each
    asking `/worker` before the next is opened and all kept open, then
    `SPREAD` more at once; prints how many of each landed on each worker,
    largest first."""
    def worker_of(sock):
        sock.sendall(h1_request("/worker", False))
        return h1_read_response(sock, with_body=True)

    kept = []
    sequential = {}
    for _ in range(SPREAD):
        sock = h1_connect(port)
        sock.settimeout(2.0)
        kept.append(sock)
        tid = worker_of(sock)
        sequential[tid] = sequential.get(tid, 0) + 1
    burst = [h1_connect(port) for _ in range(SPREAD)]
    kept += burst
    together = {}
    for sock in burst:
        sock.settimeout(2.0)
        tid = worker_of(sock)
        together[tid] = together.get(tid, 0) + 1
    order = lambda d: "/".join(str(n) for n in sorted(d.values(), reverse=True))
    print(f"spread sequential={order(sequential)} burst={order(together)}", flush=True)
    for sock in kept:
        sock.close()


def main():
    port, mode, slow_ms = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
    if mode == "spread":
        return spread(port)
    slow_s = slow_ms / 1000
    end_s = HOLD_AT_S + slow_s + TAIL_S
    bound_s = HOLD_AT_S + slow_s + ANSWER_BOUND_S

    if mode == "h1-new":
        probe = lambda t: h1_new_call(port, "/health", t)
        slow = lambda t: h1_new_call(port, f"/slow/{slow_ms}", t)
    elif mode == "h1-pool":
        pool = Pool(port)
        probe = lambda t: pool.call("/health", t)
        slow = lambda t: h1_new_call(port, f"/slow/{slow_ms}", t)
    elif mode in ("h2c-same", "h2c-other"):
        conn = H2c(port)
        assert conn.call("/health", 2.0) == 200, "h2c warm-up failed"
        slow_conn = conn
        if mode == "h2c-other":
            slow_conn = H2c(port)
            assert slow_conn.call("/health", 2.0) == 200, "h2c warm-up failed"
        probe = lambda t: conn.call("/health", t)
        slow = lambda t: slow_conn.call(f"/slow/{slow_ms}", t)
    else:
        sys.exit(f"unknown mode {mode}")

    start = time.monotonic()
    results = []  # (sent, answered or None, outcome)
    lock = threading.Lock()

    def run(fn, record):
        sent = time.monotonic() - start
        outcome = fn(max(0.1, bound_s - sent))
        done = time.monotonic() - start
        if record is not None:
            with lock:
                record.append((sent, done if outcome == 200 else None, outcome))

    slow_result = []
    threads = []
    probe_at = 0.0
    slow_sent = False
    while probe_at < end_s:
        now = time.monotonic() - start
        if not slow_sent and now >= HOLD_AT_S:
            t = threading.Thread(target=run, args=(slow, slow_result))
            t.start()
            threads.append(t)
            slow_sent = True
            continue
        if now >= probe_at:
            t = threading.Thread(target=run, args=(probe, results))
            t.start()
            threads.append(t)
            probe_at += PERIOD_S
            continue
        next_at = probe_at if slow_sent else min(probe_at, HOLD_AT_S)
        time.sleep(max(0.0, next_at - now))
    for t in threads:
        t.join()

    slow_sent_at = slow_result[0][0]
    window = [r for r in results if slow_sent_at <= r[0] < slow_sent_at + slow_s]
    answered = sorted(r[1] - r[0] for r in window if r[1] is not None)
    prompt = sum(1 for x in answered if x < PROMPT_S)
    lost_kinds = sorted({str(r[2]) for r in window if r[1] is None})
    p50 = answered[len(answered) // 2] * 1000 if answered else float("nan")
    worst = answered[-1] * 1000 if answered else float("nan")
    slow_outcome = slow_result[0][2]
    print(
        f"{mode} n={len(window)} prompt={prompt} delayed={len(answered) - prompt} "
        f"lost={len(window) - len(answered)} p50_ms={p50:.0f} max_ms={worst:.0f} "
        f"slow={slow_outcome}" + (f" lost_as={','.join(lost_kinds)}" if lost_kinds else ""),
        flush=True,
    )


if __name__ == "__main__":
    main()
