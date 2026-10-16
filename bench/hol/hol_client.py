"""The head-of-line blocking measurement's client (Python standard library
only). Not part of Muntin and not run by CI; scripts/bench_hol.sh runs it.

    python3 hol_client.py PORT MODE SLOW_MS SIGNAL

One run against a fresh server on 127.0.0.1:PORT (bench/hol/hol_muntin.mojo
or hol_flare.mojo) started with `HOL_SIGNAL=SIGNAL`, a FIFO this client
reads. It opens the connections MODE needs and asks `/worker` on each, so
every one is accepted, idle and known to belong to one worker when the hold
starts. At `HOLD_AT_S` it asks `/worker`, then `GET /slow/SLOW_MS`, on a
connection of its own (for the h2c modes, on the h2c connection named
below). That handler writes `s` to SIGNAL when it starts and `e` when it
returns; the hold is the time between the two, as this client reads them.
From the start to `HOLD_AT_S + SLOW_MS + TAIL_S` it sends `GET /health`
every `PERIOD_S`, each from its own thread, and records for each probe when
it started, when it was sent (when it began writing its request to a
connected socket: after a pool probe got its connection, after an `h1-new`
probe connected), whether that write completed (the whole request handed to
the kernel) or failed, and whether and when it was answered. A probe whose
write completed with no answer `ANSWER_BOUND_S` after the hold ended is
lost, as is one whose connection was closed or reset first; a probe whose
write failed is not lost but write-failed; a probe never sent (no pool
connection came free in time, the connection could not be opened, the h2c
connection was already gone) is neither, but not sent.

With SLOW_MS 0 (a control) no slow request is sent, and the window is the
`CONTROL_S` from `HOLD_AT_S`: what the same probes get with no handler held.

MODE is where the probes go:
- `h1-new`: each probe on a new HTTP/1.1 connection (`Connection: close`).
- `h1-pool`: HTTP/1.1 keep-alive connections, `POOL` opened before the hold;
  a probe takes an idle one, opens a new one when none is idle (no upper
  bound), and puts it back once answered.
- `h1-pool-fixed`: as `h1-pool`, but never more than `POOL` connections: a
  probe with none idle waits for one (up to the answer bound, then not
  sent).
- `h2c-same`: prior-knowledge h2c; the slow request is a stream of the
  connection every probe is a later stream of.
- `h2c-other`: as `h2c-same`, with the slow request on a second h2c
  connection.
- `spread`: no slow request; how a server spreads kept-open connections
  over its workers (`spread` below).
- `capacity-K`: K slow requests held at once, then one `/health` on a new
  connection (`capacity` below): how many blocking handlers stop a server.

It prints one line: `MODE n=<probes sent during the hold> during=<answered
before the hold ended> after=<answered after it> lost=<written, not
answered> write_failed=<write failed> p50_ms=<median latency of the
answered, from sending> max_ms=<largest> slow=<the slow request's outcome>
hold_ms=<the hold as signalled> started=<probes started during the hold>
sent_after=<of those, sent after it ended>/<lost>/<write failed>
not_sent=<probes of the run never sent>` (for a control, "the hold" is its
window), then, where the probes' connections are known (every mode but
`h1-new`, and only for connections opened before the hold),
`slow_worker=<sent>/<lost>/<write failed>` and `other_workers=` the same:
the probes on connections of the slow request's worker and of the others;
for the pool modes, `lost_idle_ms=<least>..<most>`: how long each lost
probe's connection had been idle (since its previous answer) when the probe
was sent; `lost_as`, `write_failed_as` and `not_sent_as`: why. Latency
figures cover answered probes only: read them with `lost`.
"""

import os
import socket
import struct
import sys
import threading
import time

HOLD_AT_S = 0.3
PERIOD_S = 0.05
TAIL_S = 0.7
ANSWER_BOUND_S = 3.0
CONTROL_S = 1.0
POOL = 8
SPREAD = 16


def h1_request(path, close):
    extra = "Connection: close\r\n" if close else ""
    return f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n{extra}\r\n".encode()


def h1_read_response(sock):
    """(status, body) of one response that declares its Content-Length;
    raises on EOF."""
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
    return int(head.split(b" ")[1]), body


def write(sock, data, note):
    """Writes a probe's request: note["sent"] when the write begins,
    note["written"] once all of it is handed to the kernel, or
    note["write_failed"] (why) and the error raised again."""
    note["sent"] = time.monotonic()
    try:
        sock.sendall(data)
    except OSError as e:
        note["write_failed"] = failure(e)
        raise
    note["written"] = time.monotonic()


def h1_connect(port):
    sock = socket.create_connection(("127.0.0.1", port))
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return sock


def failure(e):
    if isinstance(e, socket.timeout):
        return "timeout"
    return str(e) or type(e).__name__


class H1:
    """One HTTP/1.1 keep-alive connection, with the worker that serves it
    and when it last answered."""

    def __init__(self, port, ask_worker=True):
        self.sock = h1_connect(port)
        self.sock.settimeout(2.0)
        # A connection opened during the hold is not asked: its worker could
        # be the held one, and asking would wait for the hold.
        self.worker = self.call("/worker")[1] if ask_worker else None
        self.last = time.monotonic()

    def call(self, path):
        self.sock.sendall(h1_request(path, False))
        return h1_read_response(self.sock)


class H2c:
    """A minimal prior-knowledge h2c client: GET only, responses small enough
    for the default windows, HPACK literals without Huffman coding."""

    def __init__(self, port):
        self.port = port
        self.sock = h1_connect(port)
        self.lock = threading.Lock()
        self.next_id = 1
        self.waiting = {}  # stream id -> [event, outcome, status, body]
        self.dead = None
        self.sock.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + self.frame(4, 0, 0, b""))
        threading.Thread(target=self.read_loop, daemon=True).start()
        slot = self.get("/worker")
        if not slot[0].wait(2.0) or slot[1] != 200:
            raise ConnectionError("h2c warm-up failed")
        self.worker = slot[3]

    @staticmethod
    def frame(kind, flags, stream, payload):
        return struct.pack(">I", len(payload))[1:] + bytes([kind, flags]) + struct.pack(">I", stream) + payload

    def get(self, path, note=None):
        """Sends a GET; returns its slot, whose event is set once slot[1] holds
        the status (200) or why it failed. Records the write in note as
        `write` does."""
        authority = f"127.0.0.1:{self.port}".encode()
        block = b"\x82\x86\x04" + bytes([len(path)]) + path.encode() + b"\x01" + bytes([len(authority)]) + authority
        slot = [threading.Event(), None, None, b""]
        with self.lock:
            if self.dead is not None:
                slot[1] = self.dead
                slot[0].set()
                return slot
            stream = self.next_id
            self.next_id += 2
            try:
                write(self.sock, self.frame(1, 0x5, stream, block), {} if note is None else note)
            except OSError as e:
                slot[1] = failure(e)
                slot[0].set()
                return slot
            self.waiting[stream] = slot
        return slot

    def recv_exact(self, n):
        data = b""
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("closed")
            data += chunk
        return data

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
                elif kind == 3:  # RST_STREAM
                    self.finish(stream, "reset")
                    continue
                elif kind == 7:  # GOAWAY
                    raise ConnectionError("goaway")
                with self.lock:
                    slot = self.waiting.get(stream)
                if slot is None:
                    continue
                if kind == 1:  # HEADERS: the first field is :status
                    slot[2] = self.status(payload)
                elif kind == 0:  # DATA
                    slot[3] += payload
                if kind in (0, 1) and flags & 1:  # END_STREAM
                    self.finish(stream, slot[2] if slot[2] is not None else "no status")
        except (OSError, ConnectionError) as e:
            self.fail_all(failure(e))

    def finish(self, stream, outcome):
        with self.lock:
            slot = self.waiting.pop(stream, None)
        if slot is not None:
            slot[1] = outcome
            slot[0].set()

    def fail_all(self, reason):
        with self.lock:
            self.dead = reason
            slots = list(self.waiting.values())
            self.waiting.clear()
        for slot in slots:
            slot[1] = reason
            slot[0].set()

    def call(self, path, timeout, note=None):
        slot = self.get(path, note)
        if not slot[0].wait(timeout):
            return "timeout"
        return slot[1]


class Pool:
    """HTTP/1.1 keep-alive connections; `bounded` caps them at `POOL`."""

    def __init__(self, port, bounded):
        self.port = port
        self.bounded = bounded
        self.cond = threading.Condition()
        self.idle = [H1(port) for _ in range(POOL)]

    def take(self, timeout):
        deadline = time.monotonic() + timeout
        with self.cond:
            while not self.idle:
                if not self.bounded:
                    return None
                left = deadline - time.monotonic()
                if left <= 0 or not self.cond.wait(left):
                    raise socket.timeout()
            return self.idle.pop(0)

    def give_back(self, conn):
        with self.cond:
            if conn is not None:
                self.idle.append(conn)
            self.cond.notify()

    def probe(self, timeout, note):
        try:
            conn = self.take(timeout)
        except socket.timeout:
            return "pool-wait-timeout"
        if conn is None:
            try:
                conn = H1(self.port, ask_worker=False)
            except OSError as e:
                return "connect: " + failure(e)
        else:
            note["worker"] = conn.worker
            note["idle_ms"] = (time.monotonic() - conn.last) * 1000
        sock = conn.sock
        sock.settimeout(timeout)
        try:
            write(sock, h1_request("/health", False), note)
            status = h1_read_response(sock)[0]
        except (OSError, ConnectionError) as e:
            sock.close()
            self.give_back(None)  # a bounded pool may open a replacement
            if self.bounded:
                try:
                    replacement = H1(self.port, ask_worker=False)
                    self.give_back(replacement)
                except (OSError, ConnectionError):
                    pass
            return failure(e)
        conn.last = time.monotonic()
        self.give_back(conn)
        return status


def h1_new_call(port, path, timeout, note):
    try:
        sock = h1_connect(port)
    except OSError as e:
        return "connect: " + failure(e)
    try:
        sock.settimeout(timeout)
        write(sock, h1_request(path, True), note)
        return h1_read_response(sock)[0]
    except (OSError, ConnectionError) as e:
        return failure(e)
    finally:
        sock.close()


def ask_worker(conn):
    """Asks `/worker` on `conn` and returns the worker number; raises unless
    the answer is 200 with a number and keeps the connection open (no
    `Connection: close`)."""
    conn.sock.sendall(h1_request("/worker", False))
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.sock.recv(4096)
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    head, _, body = data.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    length = None
    for line in lines[1:]:
        name, _, value = line.partition(b":")
        name, value = name.strip().lower(), value.strip().lower()
        if name == b"content-length":
            length = int(value)
        elif name == b"connection" and b"close" in value.split(b","):
            raise ValueError("/worker answered with Connection: close")
    if length is None:
        raise ValueError("/worker answered without Content-Length")
    while len(body) < length:
        chunk = conn.sock.recv(4096)
        if not chunk:
            raise ConnectionError("closed")
        body += chunk
    if not lines[0].startswith(b"HTTP/1.1 200 ") or len(body) != length or not body.isdigit():
        raise ValueError(f"/worker answered {lines[0]!r} {body!r}")
    return body


def spread_conn(port):
    """One HTTP/1.1 connection whose `/worker` answered as `ask_worker`
    requires; raises otherwise."""
    conn = H1(port, ask_worker=False)
    try:
        conn.worker = ask_worker(conn)
    except BaseException:
        conn.sock.close()
        raise
    return conn


def spread(port):
    """Opens `SPREAD` keep-alive HTTP/1.1 connections one after another, each
    asking `/worker` before the next is opened, then `SPREAD` more from
    `SPREAD` threads released together by a barrier. Once all are open it
    asks `/worker` again on every one, so a connection counts only if it was
    still open, is reused, and names the same worker: the counts are of
    connections held open at once. Prints, for each phase, how many landed on
    each worker, busiest first, and how many of the `SPREAD` counted. Any
    failure makes the counts no measurement: it prints the failures and
    returns 1."""
    kept, failed = [], []
    for _ in range(SPREAD):
        try:
            kept.append(spread_conn(port))
        except Exception as e:
            failed.append(f"sequential: {e!r}")
    barrier = threading.Barrier(SPREAD)
    together = []
    lock = threading.Lock()

    def connect():
        try:
            barrier.wait()
            conn = spread_conn(port)
        except BaseException as e:
            with lock:
                failed.append(f"concurrent: {e!r}")
            return
        with lock:
            together.append(conn)

    threads = [threading.Thread(target=connect) for _ in range(SPREAD)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    def still_open(phase, conns):
        held = []
        for conn in conns:
            try:
                again = ask_worker(conn)
                if again != conn.worker:
                    raise ValueError(f"worker {conn.worker!r} became {again!r}")
                held.append(conn)
            except Exception as e:
                failed.append(f"{phase}, asked again: {e!r}")
        return held

    held_kept, held_together = still_open("sequential", kept), still_open("concurrent", together)

    def order(conns):
        counts = {}
        for conn in conns:
            counts[conn.worker] = counts.get(conn.worker, 0) + 1
        return "/".join(str(n) for n in sorted(counts.values(), reverse=True))

    print(f"spread sequential={order(held_kept)} ({len(held_kept)} of {SPREAD} held open) "
          f"concurrent={order(held_together)} ({len(held_together)} of {SPREAD} held open)", flush=True)
    for conn in kept + together:
        conn.sock.close()
    for f in failed:
        print(f"  failed {f}", flush=True)
    return 1 if failed else 0


def capacity(port, held, slow_ms, signal_path):
    """Holds `held` handlers at once and asks `/health` on a new connection
    while they run. Each `GET /slow/SLOW_MS` goes on a new HTTP/1.1
    connection, opened only once the previous one's handler has signalled
    its start, so the held workers no longer poll and the next connection
    goes to a worker that does; then `/health` goes on a new connection.
    Prints `capacity held=<n> health=<status> during=<yes if answered
    before the first held handler signalled its end, and when none is held>
    health_ms=<from sending> margin_ms=<that first end minus the answer, as
    this client read them; near 0 is a tie> slow=<each slow request's
    status>`; exits nonzero if the handlers do not signal, if one ended
    before all were held (the next connection went to a held worker), or if
    a request is not answered 200, a client error included."""
    fd = os.open(signal_path, os.O_RDWR)
    times = []  # (byte, when it arrived), appended by the reader as it reads
    arrived = threading.Condition()

    def read_signal():
        # O_RDWR keeps a writer present, so this read never sees EOF (Linux).
        while len(times) < 2 * held:
            byte = os.read(fd, 1).decode()
            with arrived:
                times.append((byte, time.monotonic()))
                arrived.notify_all()

    threading.Thread(target=read_signal, daemon=True).start()
    starts = lambda: [b for b, _ in times].count("s")
    # One slot per request, so a client thread that raises leaves a mark
    # instead of a missing entry that the final check would not see.
    slow = [None] * held

    def call(i, note):
        try:
            slow[i] = h1_new_call(port, f"/slow/{slow_ms}", slow_ms / 1000 + ANSWER_BOUND_S, note)
        except Exception as e:
            slow[i] = f"{type(e).__name__}: {e}"

    threads = []
    for i in range(held):
        t = threading.Thread(target=call, args=(i, {}), daemon=True)
        t.start()
        threads.append(t)
        with arrived:
            if not arrived.wait_for(lambda: starts() == i + 1, ANSWER_BOUND_S):
                sys.exit(f"capacity: handler {i + 1} of {held} did not signal its start: {times}")
    with arrived:
        if any(b == "e" for b, _ in times):
            sys.exit(f"capacity: a handler ended before {held} were held: {times}")
    note = {}
    status = h1_new_call(port, "/health", slow_ms / 1000 + ANSWER_BOUND_S, note)
    done = time.monotonic()
    for t in threads:
        t.join()
    with arrived:
        if not arrived.wait_for(lambda: len(times) == 2 * held, ANSWER_BOUND_S):
            sys.exit(f"capacity: the held handlers did not signal their ends: {times}")
    ends = [at for b, at in times if b == "e"]
    during = "yes" if not ends or done < min(ends) else "no"
    margin = f"{(min(ends) - done) * 1000:.1f}" if ends else "none"
    health_ms = (done - note["sent"]) * 1000 if "sent" in note else float("nan")
    print(
        f"capacity held={held} health={status} during={during} health_ms={health_ms:.0f} margin_ms={margin} "
        f"slow={','.join(str(s) for s in slow) or 'none'}",
        flush=True,
    )
    if status != 200 or any(s != 200 for s in slow):
        sys.exit("capacity: a request was not answered 200")


class Signal:
    """Reads the slow handler's `s` and `e` from the FIFO, with the time each
    arrived."""

    def __init__(self, path):
        # O_RDWR keeps a writer present, so the server's open never blocks
        # and this read never sees EOF between the two bytes (Linux).
        self.fd = os.open(path, os.O_RDWR)
        self.times = {}
        self.done = threading.Event()
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        while len(self.times) < 2:
            byte = os.read(self.fd, 1).decode()
            self.times[byte] = time.monotonic()
        self.done.set()


def main():
    port, mode, slow_ms, signal_path = int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4]
    if mode == "spread":
        return spread(port)
    if mode.startswith("capacity-"):
        return capacity(port, int(mode.removeprefix("capacity-")), slow_ms, signal_path)
    control = slow_ms == 0
    slow_s = slow_ms / 1000 if not control else CONTROL_S
    end_s = HOLD_AT_S + slow_s + TAIL_S
    bound_s = HOLD_AT_S + slow_s + ANSWER_BOUND_S
    signal = None if control else Signal(signal_path)

    slow_conn = None  # (worker, call)
    if mode == "h1-new":
        probe = lambda t, note: h1_new_call(port, "/health", t, note)
    elif mode in ("h1-pool", "h1-pool-fixed"):
        pool = Pool(port, mode == "h1-pool-fixed")
        probe = pool.probe
    elif mode in ("h2c-same", "h2c-other"):
        conn = H2c(port)
        probe_conn = conn

        def probe(t, note):
            note["worker"] = probe_conn.worker
            return probe_conn.call("/health", t, note)

        if mode == "h2c-other":
            conn = H2c(port)
        slow_conn = (conn.worker, lambda t: conn.call(f"/slow/{slow_ms}", t))
    else:
        sys.exit(f"unknown mode {mode}")
    if slow_conn is None and not control:
        h1 = H1(port)

        def slow_call(t):
            h1.sock.settimeout(t)
            try:
                return h1.call(f"/slow/{slow_ms}")[0]
            except (OSError, ConnectionError) as e:
                return failure(e)

        slow_conn = (h1.worker, slow_call)

    start = time.monotonic()
    # One dict per probe: started, sent (absent if never sent), done (when
    # answered or failed), outcome (200 or why not), and for kept-open
    # connections worker and idle_ms.
    results = []
    lock = threading.Lock()
    slow_result = []

    def run_probe():
        note = {"started": time.monotonic()}
        note["outcome"] = probe(max(0.1, start + bound_s - note["started"]), note)
        note["done"] = time.monotonic()
        with lock:
            results.append(note)

    def run_slow():
        slow_result.append(slow_conn[1](max(0.1, bound_s)))

    threads = []
    probe_at = 0.0
    slow_sent = control
    while probe_at < end_s:
        now = time.monotonic() - start
        if not slow_sent and now >= HOLD_AT_S:
            threads.append(threading.Thread(target=run_slow))
            threads[-1].start()
            slow_sent = True
            continue
        if now >= probe_at:
            threads.append(threading.Thread(target=run_probe))
            threads[-1].start()
            probe_at += PERIOD_S
            continue
        next_at = probe_at if slow_sent else min(probe_at, HOLD_AT_S)
        time.sleep(max(0.0, next_at - now))
    for t in threads:
        t.join()

    if control:
        hold_from, hold_to = start + HOLD_AT_S, start + HOLD_AT_S + CONTROL_S
        slow_outcome, slow_worker = "none", None
    else:
        if not signal.done.wait(ANSWER_BOUND_S) or set(signal.times) != {"s", "e"}:
            sys.exit(f"{mode}: the slow handler did not signal its start and end: {signal.times}")
        hold_from, hold_to = signal.times["s"], signal.times["e"]
        slow_outcome, slow_worker = slow_result[0], slow_conn[0]
    ok = lambda r: r["outcome"] == 200
    is_lost = lambda r: "written" in r and not ok(r)
    count = lambda rs: f"{len(rs)}/{sum(map(is_lost, rs))}/{sum('write_failed' in r for r in rs)}"
    window = [r for r in results if "sent" in r and hold_from <= r["sent"] < hold_to]
    answered = sorted(r["done"] - r["sent"] for r in window if ok(r))
    during = sum(1 for r in window if ok(r) and r["done"] < hold_to)
    lost = [r for r in window if is_lost(r)]
    lost_kinds = sorted({str(r["outcome"]) for r in lost})
    write_failed = [r for r in window if "write_failed" in r]
    started = [r for r in results if hold_from <= r["started"] < hold_to]
    sent_after = [r for r in started if "sent" in r and r["sent"] >= hold_to]
    not_sent = [r for r in results if "sent" not in r]
    p50 = answered[len(answered) // 2] * 1000 if answered else float("nan")
    worst = answered[-1] * 1000 if answered else float("nan")
    line = (
        f"{mode} n={len(window)} during={during} after={len(answered) - during} "
        f"lost={len(lost)} write_failed={len(write_failed)} p50_ms={p50:.0f} max_ms={worst:.0f} slow={slow_outcome} "
        f"hold_ms={(hold_to - hold_from) * 1000:.0f} started={len(started)} "
        f"sent_after={count(sent_after)} not_sent={len(not_sent)}"
    )
    if mode != "h1-new" and not control:
        known = [r for r in window if r.get("worker") is not None]
        same = [r for r in known if r["worker"] == slow_worker]
        other = [r for r in known if r["worker"] != slow_worker]
        line += f" slow_worker={count(same)} other_workers={count(other)}"
    idles = sorted(r["idle_ms"] for r in lost if "idle_ms" in r)
    if idles:
        line += f" lost_idle_ms={idles[0]:.0f}..{idles[-1]:.0f}"
    if lost_kinds:
        line += f" lost_as={','.join(lost_kinds)}"
    if write_failed:
        line += f" write_failed_as={','.join(sorted({r['write_failed'] for r in write_failed}))}"
    if not_sent:
        line += f" not_sent_as={','.join(sorted({str(r['outcome']) for r in not_sent}))}"
    print(line, flush=True)


if __name__ == "__main__":
    sys.exit(main())
