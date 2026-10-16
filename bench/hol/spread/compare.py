"""M3-069's comparison client (Python standard library only). Not part of
Muntin and not run by CI; run_spread.sh runs it against hol_muntin servers
with 4 workers (bench/hol/hol_muntin.mojo: `/slow/{ms}` blocks its worker and
writes `s` and `e` to the server's FIFO, `/worker` names the worker).

A server is given as NAME=PORT,FIFO,PID; `stop` takes NAME=BINARY and starts
its own. Every mode prints one line per server (prefixed by NAME) and exits 1
when the run is no measurement: a connection lost, an answer that is not a
complete 200, a hold it could not set up.

- `backlog SERVER`: holds every worker (each `/slow/6000` on a connection
  opened only once the previous handler has signalled its start; a
  connection that lands on a held worker, unanswered after 200 ms, is set
  aside), then opens 16
  connections, each sending `/worker`, while all are held. Prints how many
  each worker answered once the holds ended, busiest first.
- `keepalive SERVER`: 16 keep-alive connections opened one after another,
  each sending `/health` back to back from its own thread for 5 s. Prints
  answered requests per second, p50 and p99 latency, the server's CPU
  seconds (utime + stime) per 1000 answered, failures, and the connections'
  spread over workers when opened (each is opened again after Flare closes
  it at its 100th request; `reopened` counts those).
- `steady SERVER`: the same 16 connections, each sending one `/health` every
  10 ms (1600 per second in all); latency counts from when a request was
  due, so a late one is not hidden. Adds p99.9.
- `arrivals SERVER`: 8 keep-alive connections paced as `steady` (one
  `/health` every 5 ms each) while bursts of 32 new connections arrive every
  20 ms for 5 s, each sending `/health` with `Connection: close` as soon as
  it is connected. Prints the kept-open requests' p50, p99 and p99.9 from
  when they were due, the arrivals opened and answered and their p99, the
  server's CPU per 1000 answered, and fails if any arrival is not answered
  within 3 s of the end (a listener left with a backlog not served again).
- `trials N SERVER...`: N rounds; in each, for every server in a shuffled
  order, a hold-wait trial and an after-hold trial on a pool of 8
  keep-alive connections opened at the start. Hold-wait: `/slow/100` on a
  pool connection and, released by the same barrier, a new connection
  sending `/worker` with `Connection: close` (a pool connection Flare
  closes at its 100th request is replaced). After-hold: the same, the new
  connection opened only once the handler has signalled its start (M3-049's
  contract: answered by another idle worker). A trial's new connection
  waited if it was answered after the handler signalled its end. Prints,
  per server and kind, waited/N, how many of those went to the slow
  request's worker, failures, and against `pin` the difference with its
  Newcombe 95% confidence interval and a one-sided Fisher exact p for a
  rise.
- `stop N NAME=BINARY...`: N rounds; in each, for every binary in a shuffled
  order, starts it (`BINARY 4 60000 200`: a 200 ms grace window), checks one
  `/health`, sends SIGTERM and, after a uniform 0 to 60 ms (the stop watcher
  polls every 50 ms), opens a connection sending `/health`. Outcomes: `ok`,
  `refused` (connect refused: the listener had closed), `reset` (connected,
  then reset or closed with no complete answer), `timeout` (3 s). Also
  requires the server to exit 0 within 3 s. Prints counts and, against
  `pin`, the same statistics on `reset`.
- `sequential PORT N`: N new connections one after another, each `/health`
  with `Connection: close` and a 2 s timeout; prints each outcome; exits 1
  unless all are `ok`.
- `churnstop PORT PID`: 8 threads open connections in a loop (`/health`,
  `Connection: close`) for 2 s; SIGTERM goes to PID at 1 s. Prints outcomes
  before and after the signal; exits 1 if any attempt started before it was
  not answered.
"""

import math
import os
import random
import selectors
import signal as signals
import socket
import subprocess
import sys
import threading
import time

WORKERS = 4


def request(path, close=False):
    extra = "Connection: close\r\n" if close else ""
    return f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n{extra}\r\n".encode()


def parse(data):
    """(status, body, closes) of a complete response in `data`, or None if
    `data` does not hold one yet; raises on a malformed head."""
    head, sep, rest = data.partition(b"\r\n\r\n")
    if not sep:
        return None
    lines = head.split(b"\r\n")
    length, closes = None, False
    for line in lines[1:]:
        name, _, value = line.partition(b":")
        name, value = name.strip().lower(), value.strip().lower()
        if name == b"content-length":
            length = int(value)
        elif name == b"connection" and b"close" in value.split(b","):
            closes = True
    if length is None:
        raise ValueError("no Content-Length")
    if len(rest) < length:
        return None
    return int(lines[0].split(b" ")[1]), rest[:length], closes


def read_response(sock):
    data = b""
    while True:
        got = parse(data)
        if got is not None:
            return got
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("closed before a complete answer")
        data += chunk


def outcome(e):
    if isinstance(e, ConnectionRefusedError):
        return "refused"
    if isinstance(e, (socket.timeout, TimeoutError)):
        return "timeout"
    if isinstance(e, (ConnectionResetError, ConnectionError, BrokenPipeError)):
        return "reset"
    return type(e).__name__


class Conn:
    """One keep-alive HTTP/1.1 connection."""

    def __init__(self, port, timeout=3.0):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.port = port
        self.worker = None
        self.reopened = 0

    def call(self, path, reopen=False):
        """`path`'s body; raises unless 200 on a connection kept open. With
        `reopen`, an answer that closes the connection (Flare closes one
        after 100 requests, its `max_keepalive_requests`) counts, and the
        next call goes on a new connection."""
        self.sock.sendall(request(path))
        status, body, closes = read_response(self.sock)
        if status != 200 or (closes and not reopen):
            raise ValueError(f"{path} answered {status}, closes={closes}")
        if closes:
            self.sock.close()
            self.sock = socket.create_connection(("127.0.0.1", self.port), timeout=3.0)
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self.reopened += 1
        return body

    def ask_worker(self):
        self.worker = self.call("/worker")
        return self.worker


class Signal:
    """The server's FIFO: each `s` and `e` its slow handler writes, with when
    it arrived."""

    def __init__(self, path):
        # O_RDWR keeps a writer present, so reads never see EOF (Linux).
        self.fd = os.open(path, os.O_RDWR)
        self.seen = []
        self.cond = threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while True:
            byte = os.read(self.fd, 1).decode()
            with self.cond:
                self.seen.append((byte, time.monotonic()))
                self.cond.notify_all()

    def wait(self, count, timeout):
        """Waits until `count` bytes have arrived in all; False if not."""
        with self.cond:
            return self.cond.wait_for(lambda: len(self.seen) >= count, timeout)


def server(arg):
    name, _, rest = arg.partition("=")
    port, fifo, pid = rest.split(",")
    return name, int(port), fifo, int(pid)


def cpu(pid):
    with open(f"/proc/{pid}/stat") as f:
        parts = f.read().rsplit(")", 1)[1].split()
    return (int(parts[11]) + int(parts[12])) / os.sysconf("SC_CLK_TCK")


def pct(values, q):
    if not values:
        return float("nan")
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * q))] * 1000


def spread_of(conns):
    counts = {}
    for c in conns:
        counts[c.worker] = counts.get(c.worker, 0) + 1
    return "/".join(str(n) for n in sorted(counts.values(), reverse=True))


# ── statistics ────────────────────────────────────────────────────────────


def fisher_rise(a, n1, b, n2):
    """One-sided Fisher exact p that the first group's rate (a of n1) exceeds
    the second's (b of n2): P(X >= a) for X hypergeometric."""
    total, k = n1 + n2, a + b
    denom = math.comb(total, k)
    return sum(math.comb(n1, x) * math.comb(n2, k - x) for x in range(a, min(n1, k) + 1)) / denom


def wilson(x, n, z=1.959964):
    p = x / n
    centre = (p + z * z / (2 * n)) / (1 + z * z / n)
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    return centre - half, centre + half


def newcombe(a, n1, b, n2):
    """Difference a/n1 - b/n2 and its Newcombe (hybrid Wilson) 95% interval."""
    p1, p2 = a / n1, b / n2
    l1, u1 = wilson(a, n1)
    l2, u2 = wilson(b, n2)
    d = p1 - p2
    return d, d - math.sqrt((p1 - l1) ** 2 + (u2 - p2) ** 2), d + math.sqrt((u1 - p1) ** 2 + (p2 - l2) ** 2)


def against_pin(x, n, pin_x, pin_n):
    d, lo, hi = newcombe(x, n, pin_x, pin_n)
    return f"diff {d * 100:+.1f} pp [{lo * 100:+.1f}, {hi * 100:+.1f}] fisher_p {fisher_rise(x, n, pin_x, pin_n):.3g}"


# ── modes ─────────────────────────────────────────────────────────────────


def backlog(arg):
    name, port, fifo, _ = server(arg)
    sig = Signal(fifo)
    held, aside, slow = {}, [], []

    def finish_slow(conn, slot):
        try:
            status, _, _ = read_response(conn.sock)
            slot.append(status)
        except Exception as e:
            slot.append(outcome(e))

    for _ in range(64):
        if len(held) == WORKERS:
            break
        conn = Conn(port, timeout=0.2)
        try:
            worker = conn.ask_worker()
        except (socket.timeout, TimeoutError):
            aside.append(conn)  # on a held worker
            continue
        conn.sock.settimeout(8.0)
        conn.sock.sendall(request("/slow/6000"))
        if not sig.wait(len(held) + 1, 2.0):
            sys.exit(f"backlog {name}: handler {len(held) + 1} did not signal its start")
        if worker in held:
            sys.exit(f"backlog {name}: worker {worker!r} answered /worker while held "
                     f"(its handler signals: {[b for b, _ in sig.seen]})")
        held[worker] = conn
        t = threading.Thread(target=finish_slow, args=(conn, slow))
        t.start()
        conn.thread = t
    if len(held) != WORKERS:
        sys.exit(f"backlog {name}: held {len(held)} workers")
    if any(b == "e" for b, _ in sig.seen):
        sys.exit(f"backlog {name}: a handler ended before every worker was held")
    waiting = []
    for _ in range(16):
        conn = Conn(port, timeout=8.0)
        conn.sock.sendall(request("/worker"))
        waiting.append(conn)
    if any(b == "e" for b, _ in sig.seen):
        sys.exit(f"backlog {name}: a handler ended while the backlog was opened")
    failed = []
    for conn in waiting:
        try:
            status, body, closes = read_response(conn.sock)
            if status != 200 or closes:
                raise ValueError(f"{status} closes={closes}")
            conn.worker = body
        except Exception as e:
            failed.append(outcome(e))
    for conn in held.values():
        conn.thread.join()
    answered = [c for c in waiting if c.worker is not None]
    print(f"backlog {spread_of(answered)} ({len(answered)} of 16; set aside {len(aside)}) "
          f"slow={','.join(map(str, slow))}", flush=True)
    if failed or any(s != 200 for s in slow):
        print(f"  failed {failed}", flush=True)
        return 1
    return 0


def open_pool(port, n):
    conns = []
    for _ in range(n):
        c = Conn(port)
        c.ask_worker()
        conns.append(c)
    return conns


def keepalive(arg, paced_s=None, seconds=5.0, n=16, label="keepalive"):
    name, port, _, pid = server(arg)
    conns = open_pool(port, n)
    lat, fails, lock = [], {}, threading.Lock()
    start = time.monotonic() + 0.1
    end = start + seconds

    def run(conn, offset):
        mine, bad = [], {}
        due = start + offset
        try:
            while True:
                if paced_s is not None:
                    now = time.monotonic()
                    if due > now:
                        time.sleep(due - now)
                    t0 = due
                    due += paced_s
                else:
                    t0 = time.monotonic()
                if t0 >= end:
                    break
                try:
                    if conn.call("/health", reopen=True) != b"ok":
                        raise ValueError("body")
                    mine.append(time.monotonic() - t0)
                except Exception as e:
                    bad[outcome(e)] = bad.get(outcome(e), 0) + 1
                    break
        finally:
            with lock:
                lat.extend(mine)
                for k, v in bad.items():
                    fails[k] = fails.get(k, 0) + v

    c0 = cpu(pid)
    threads = [threading.Thread(target=run, args=(c, (paced_s or 0) * i / n)) for i, c in enumerate(conns)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    c1 = cpu(pid)
    answered = len(lat)
    extra = f" p99.9 {pct(lat, 0.999):.2f}" if paced_s is not None else ""
    print(f"{label} rate {answered / seconds:.0f}/s p50 {pct(lat, 0.5):.2f} p99 {pct(lat, 0.99):.2f}{extra} ms "
          f"cpu_s/1000 {(c1 - c0) * 1000 / max(answered, 1):.3f} failed {sum(fails.values())} {fails or ''} "
          f"spread {spread_of(conns)} reopened {sum(c.reopened for c in conns)}", flush=True)
    return 1 if fails or not answered else 0


def arrivals(arg):
    name, port, _, pid = server(arg)
    conns = open_pool(port, 8)
    seconds, burst, every = 5.0, 32, 0.02
    lat, fails, lock = [], {}, threading.Lock()
    start = time.monotonic() + 0.1
    end = start + seconds

    def probe(conn, offset):
        due = start + offset
        while due < end:
            now = time.monotonic()
            if due > now:
                time.sleep(due - now)
            try:
                if conn.call("/health", reopen=True) != b"ok":
                    raise ValueError("body")
                with lock:
                    lat.append(time.monotonic() - due)
            except Exception as e:
                with lock:
                    fails[outcome(e)] = fails.get(outcome(e), 0) + 1
                return
            due += 0.005

    sel = selectors.DefaultSelector()
    opened, answered_lat, arrival_fails = [0], [], {}
    pending = {}

    def open_burst():
        for _ in range(burst):
            s = socket.socket()
            s.setblocking(False)
            err = s.connect_ex(("127.0.0.1", port))
            if err not in (0, 115):  # EINPROGRESS
                arrival_fails[f"connect {err}"] = arrival_fails.get(f"connect {err}", 0) + 1
                s.close()
                continue
            opened[0] += 1
            pending[s] = [time.monotonic(), b"", False]
            sel.register(s, selectors.EVENT_WRITE)

    def arrive():
        due = start
        while True:
            now = time.monotonic()
            if due < end and now >= due:
                open_burst()
                due += every
            if due >= end and not pending:
                return
            if due >= end and now > end + 3.0:
                return
            timeout = max(0.0, min(due, end + 3.0) - now) if due < end else 0.05
            for key, ev in sel.select(timeout):
                s = key.fileobj
                st = pending[s]
                try:
                    if not st[2]:
                        err = s.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
                        if err:
                            raise ConnectionRefusedError(err, os.strerror(err))
                        s.send(request("/health", close=True))
                        st[2] = True
                        sel.modify(s, selectors.EVENT_READ)
                        continue
                    chunk = s.recv(4096)
                    if not chunk:
                        raise ConnectionError("closed before a complete answer")
                    st[1] += chunk
                    got = parse(st[1])
                    if got is None:
                        continue
                    if got[0] != 200 or got[1] != b"ok":
                        raise ValueError(f"answered {got[0]}")
                    answered_lat.append(time.monotonic() - st[0])
                except Exception as e:
                    arrival_fails[outcome(e)] = arrival_fails.get(outcome(e), 0) + 1
                sel.unregister(s)
                s.close()
                del pending[s]

    c0 = cpu(pid)
    threads = [threading.Thread(target=probe, args=(c, 0.005 * i / 8)) for i, c in enumerate(conns)]
    threads.append(threading.Thread(target=arrive))
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    c1 = cpu(pid)
    unanswered = len(pending)
    for s in list(pending):
        s.close()
    total = len(lat) + len(answered_lat)
    print(f"arrivals kept p50 {pct(lat, 0.5):.2f} p99 {pct(lat, 0.99):.2f} p99.9 {pct(lat, 0.999):.2f} ms "
          f"({len(lat)} answered, failed {sum(fails.values())} {fails or ''}) "
          f"new {len(answered_lat)} of {opened[0]} p99 {pct(answered_lat, 0.99):.2f} ms unanswered {unanswered} "
          f"failed {sum(arrival_fails.values())} {arrival_fails or ''} "
          f"cpu_s/1000 {(c1 - c0) * 1000 / max(total, 1):.3f}", flush=True)
    return 1 if fails or arrival_fails or unanswered or not lat else 0


def new_worker_call(port, timeout=3.0):
    """`/worker` on a new connection with `Connection: close`: (worker,
    answered at) or raises."""
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    try:
        s.sendall(request("/worker", close=True))
        status, body, _ = read_response(s)
        if status != 200:
            raise ValueError(f"answered {status}")
        return body, time.monotonic()
    finally:
        s.close()


def trials(n, args):
    servers = []
    for arg in args:
        name, port, fifo, _ = server(arg)
        servers.append({"name": name, "port": port, "sig": Signal(fifo), "pool": open_pool(port, 8),
                        "hold": [0, 0, {}], "after": [0, 0, {}], "n": 0})

    def trial(s, kind):
        conn = random.choice(s["pool"])
        base = len(s["sig"].seen)
        barrier = threading.Barrier(2)
        slow = []

        closes = []

        def send_slow():
            try:
                barrier.wait()
                conn.sock.sendall(request("/slow/100"))
                status, _, closed = read_response(conn.sock)
                slow.append(status)
                closes.append(closed)
            except Exception as e:
                slow.append(outcome(e))

        t = threading.Thread(target=send_slow)
        t.start()
        barrier.wait()
        if kind == "after" and not s["sig"].wait(base + 1, 2.0):
            sys.exit(f"trials {s['name']}: the slow handler did not signal its start")
        tally = s[kind]
        try:
            worker, at = new_worker_call(s["port"])
        except Exception as e:
            worker, at = None, None
            tally[2][outcome(e)] = tally[2].get(outcome(e), 0) + 1
        t.join()
        if slow != [200]:
            sys.exit(f"trials {s['name']}: the slow request answered {slow}")
        if closes == [True]:  # Flare's 100th request on that connection
            conn.sock.close()
            fresh = Conn(s["port"])
            fresh.ask_worker()
            s["pool"][s["pool"].index(conn)] = fresh
        if not s["sig"].wait(base + 2, 2.0):
            sys.exit(f"trials {s['name']}: the slow handler did not signal its end")
        ended = s["sig"].seen[base + 1][1]
        if at is not None and at > ended:
            tally[0] += 1
            if worker == conn.worker:
                tally[1] += 1

    for _ in range(n):
        order = servers[:]
        random.shuffle(order)
        for s in order:
            trial(s, "hold")
            trial(s, "after")
            s["n"] += 1
    pin = next((s for s in servers if s["name"] == "pin"), None)
    failed = False
    for s in servers:
        for kind, label in (("hold", "hold-wait"), ("after", "after-hold")):
            waited, same, fails = s[kind]
            line = f"{s['name']} {label} waited {waited}/{s['n']} (on the slow worker {same}) failed {sum(fails.values())} {fails or ''}"
            if pin is not None and s is not pin:
                line += " " + against_pin(waited, s["n"], pin[kind][0], pin["n"])
            print(line, flush=True)
            failed |= bool(fails)
    return 1 if failed else 0


def stop(n, args):
    variants = [dict(zip(("name", "binary"), a.split("=", 1))) for a in args]
    for v in variants:
        v["counts"] = {}
        v["n"] = 0
    bad = []

    def one(v):
        p = subprocess.Popen([v["binary"], "4", "60000", "200"], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True)
        line = p.stdout.readline().split()
        if len(line) != 2 or line[0] != "port":
            p.kill()
            sys.exit(f"stop {v['name']}: no port: {line}")
        port = int(line[1])
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=3)
            s.sendall(request("/health", close=True))
            if read_response(s)[0] != 200:
                raise ValueError("not 200")
            s.close()
        except Exception as e:
            p.kill()
            rest = p.communicate()[0]
            bad.append(f"{v['name']}: the check before the stop: {outcome(e)} (port {port}): {rest.strip()[:300]}")
            return
        delay = random.uniform(0, 0.06)
        p.send_signal(signals.SIGTERM)
        time.sleep(delay)
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=3)
            try:
                s.sendall(request("/health", close=True))
                status, body, _ = read_response(s)
                result = "ok" if status == 200 and body == b"ok" else f"status {status}"
            finally:
                s.close()
        except Exception as e:
            result = outcome(e)
        v["counts"][result] = v["counts"].get(result, 0) + 1
        v["n"] += 1
        try:
            code = p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
            code = "timeout"
        rest = p.stdout.read()
        if code != 0:
            bad.append(f"{v['name']}: exit {code}: {rest.strip()[:200]}")

    for _ in range(n):
        order = variants[:]
        random.shuffle(order)
        for v in order:
            one(v)
    pin = next((v for v in variants if v["name"] == "pin"), None)
    for v in variants:
        counts = " ".join(f"{k} {c}" for k, c in sorted(v["counts"].items()))
        line = f"{v['name']} stop {counts} of {v['n']}"
        if pin is not None and v is not pin:
            line += " reset " + against_pin(v["counts"].get("reset", 0), v["n"], pin["counts"].get("reset", 0), pin["n"])
        print(line, flush=True)
    for b in bad:
        print(f"  failed {b}", flush=True)
    return 1 if bad else 0


def sequential(port, n):
    results = []
    for _ in range(n):
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=2)
            try:
                s.sendall(request("/health", close=True))
                status, body, _ = read_response(s)
                results.append("ok" if status == 200 and body == b"ok" else f"status-{status}")
            finally:
                s.close()
        except Exception as e:
            results.append(outcome(e))
    print(" ".join(results), flush=True)
    return 0 if all(r == "ok" for r in results) else 1


def churnstop(port, pid):
    start = time.monotonic()
    signalled = [None]
    end = start + 2.0
    before, after, lock = {}, {}, threading.Lock()

    def run():
        while time.monotonic() < end:
            t0 = time.monotonic()
            try:
                s = socket.create_connection(("127.0.0.1", port), timeout=3)
                try:
                    s.sendall(request("/health", close=True))
                    status, body, _ = read_response(s)
                    result = "ok" if status == 200 and body == b"ok" else f"status-{status}"
                finally:
                    s.close()
            except Exception as e:
                result = outcome(e)
            with lock:
                into = before if signalled[0] is None or t0 < signalled[0] else after
                into[result] = into.get(result, 0) + 1

    threads = [threading.Thread(target=run) for _ in range(8)]
    for t in threads:
        t.start()
    time.sleep(1.0)
    with lock:
        signalled[0] = time.monotonic()
    os.kill(pid, signals.SIGTERM)
    for t in threads:
        t.join()
    print(f"before {before} after {after}", flush=True)
    return 0 if set(before) == {"ok"} else 1


def main():
    mode = sys.argv[1]
    if mode == "backlog":
        return backlog(sys.argv[2])
    if mode == "keepalive":
        return keepalive(sys.argv[2])
    if mode == "steady":
        return keepalive(sys.argv[2], paced_s=0.01, label="steady")
    if mode == "arrivals":
        return arrivals(sys.argv[2])
    if mode == "trials":
        return trials(int(sys.argv[2]), sys.argv[3:])
    if mode == "stop":
        return stop(int(sys.argv[2]), sys.argv[3:])
    if mode == "sequential":
        return sequential(int(sys.argv[2]), int(sys.argv[3]))
    if mode == "churnstop":
        return churnstop(int(sys.argv[2]), int(sys.argv[3]))
    sys.exit(f"unknown mode {mode}")


if __name__ == "__main__":
    sys.exit(main())
