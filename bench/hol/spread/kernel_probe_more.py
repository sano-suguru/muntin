"""More Linux kernel probes for the worker-spread decision (M3-068, review of #120).

backlog: 16 connections are queued on one listener before any of 4 workers
polls; then all 4 poll. Modes: plain (no EPOLLEXCLUSIVE, Flare v0.12.0 as
it runs today), rotate (EPOLLEXCLUSIVE, DEL+ADD after each accept batch),
rotate-cap1 (the same, accepting at most one connection per wake-up).

burst: 4 workers already polling; 4 client threads each open 16
connections as fast as they can (64 in all), kept open. Modes: plain,
exclusive (no re-registration), rotate.

stop: the M3-045 parking sequence against the re-registration, single
threaded so every interleaving is forced: a worker's copy W of the listener
L is registered EPOLLIN|EPOLLEXCLUSIVE in epoll E, one connection C is
accepted and registered, then the watcher's dup2(parking pipe, W) is placed
before, between or after the worker's DEL and ADD of W, and L is closed.

backlog and burst print connections per worker, busiest first, every
worker listed (0 for one that took none). A worker
that fails to register or fails later, or a connection no worker accepted,
ends the probe with an error (exit 1): its counts would not be of 4 workers.
"""
import errno, os, select, socket, sys, threading, time
from collections import Counter

EXCL = select.EPOLLEXCLUSIVE


def make_listener():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    s.listen(1024)
    s.setblocking(False)
    return s


def worker(idx, lsock, mode, owner, go, stop, ready, errors):
    """Runs one worker; any exception, its registration's included, goes to
    `errors` for `run` to fail on."""
    try:
        ep = select.epoll()
        flags = select.EPOLLIN | (0 if mode == "plain" else EXCL)
        ep.register(lsock.fileno(), flags)
        ready.release()
        conns = []
        go.wait()
        while not stop.is_set():
            for fd, ev in ep.poll(0.05):
                n = 0
                while True:
                    if mode == "rotate-cap1" and n == 1:
                        break
                    try:
                        c, _ = lsock.accept()
                    except BlockingIOError:
                        break
                    conns.append(c)
                    owner[c.getpeername()[1]] = idx
                    n += 1
                if mode.startswith("rotate"):
                    ep.unregister(lsock.fileno())
                    ep.register(lsock.fileno(), flags)
        ep.close()
        for c in conns:
            c.close()
    except BaseException as e:
        errors.append(f"worker {idx}: {e!r}")


def run(kind, mode, workers=4):
    """Connections per worker, busiest first, every worker listed. Raises if
    a worker fails to start or fails later, or if a connection is never
    accepted: the counts would then not be of `workers` workers."""
    lsock = make_listener()
    port = lsock.getsockname()[1]
    owner, go, stop = {}, threading.Event(), threading.Event()
    ready, errors = threading.Semaphore(0), []
    ts = [threading.Thread(target=worker, args=(i, lsock, mode, owner, go, stop, ready, errors), daemon=True)
          for i in range(workers)]
    for t in ts:
        t.start()
    clients = []
    try:
        for _ in range(workers):
            if not ready.acquire(timeout=2) or errors:
                raise RuntimeError(f"{kind} {mode}: a worker did not start: {errors}")
        if kind == "backlog":
            for _ in range(16):
                clients.append(socket.create_connection(("127.0.0.1", port)))
            time.sleep(0.05)
            go.set()
        else:
            go.set()
            time.sleep(0.1)
            lock = threading.Lock()
            opener_errors = []

            def opener():
                try:
                    mine = [socket.create_connection(("127.0.0.1", port)) for _ in range(16)]
                except OSError as e:
                    opener_errors.append(e)
                    return
                with lock:
                    clients.extend(mine)

            os_ = [threading.Thread(target=opener) for _ in range(4)]
            for t in os_:
                t.start()
            for t in os_:
                t.join()
            if opener_errors:
                raise RuntimeError(f"burst: {len(opener_errors)} of 4 openers failed: {opener_errors[0]!r}")
        deadline = time.monotonic() + 2
        ports = [c.getsockname()[1] for c in clients]
        while time.monotonic() < deadline and not all(p in owner for p in ports):
            time.sleep(0.005)
        stop.set()
        for t in ts:
            t.join(2)
        if errors or any(t.is_alive() for t in ts):
            raise RuntimeError(f"{kind} {mode}: a worker failed: {errors or 'did not stop'}")
        missing = sum(1 for p in ports if p not in owner)
        if missing:
            raise RuntimeError(f"{kind} {mode}: {missing} of {len(ports)} connections never accepted")
        counts = Counter(owner[p] for p in ports)
        return sorted((counts.get(i, 0) for i in range(workers)), reverse=True)
    finally:
        stop.set()
        for c in clients:
            c.close()
        lsock.close()


def ctl(fn):
    try:
        fn()
        return "ok"
    except OSError as e:
        return errno.errorcode.get(e.errno, str(e.errno))


def stop_order(order):
    lsock = make_listener()
    port = lsock.getsockname()[1]
    w = os.dup(lsock.fileno())
    os.set_inheritable(w, False)
    r, wr = os.pipe()
    ep = select.epoll()
    ep.register(w, select.EPOLLIN | EXCL)
    cli = socket.create_connection(("127.0.0.1", port))
    ep.poll(0.2)
    c = socket.socket(fileno=os.dup(w)).accept()[0]
    c.setblocking(False)
    ep.register(c.fileno(), select.EPOLLIN)
    log = []
    park = lambda: os.dup2(r, w)
    dele = lambda: log.append("DEL " + ctl(lambda: ep.unregister(w)))
    add = lambda: log.append("ADD " + ctl(lambda: ep.register(w, select.EPOLLIN | EXCL)))
    steps = {"park,DEL,ADD": (park, dele, add), "DEL,park,ADD": (dele, park, add), "DEL,ADD,park": (dele, add, park)}[order]
    for s in steps:
        s()
    # Window between parking and closing the Server's listener: a new
    # connection still queues on the listener.
    early = socket.socket()
    early.setblocking(False)
    early.connect_ex(("127.0.0.1", port))
    time.sleep(0.02)
    win = ep.poll(0.05)
    win_w = sum(1 for fd, _ in win if fd == w)
    acc = ctl(lambda: socket.socket(fileno=os.dup(w)).accept())
    lsock.close()
    time.sleep(0.02)
    # After the close: refused, the open connection still served, and no
    # event for W (stale or parked).
    try:
        socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
        refused = "accepted"
    except ConnectionRefusedError:
        refused = "refused"
    cli.sendall(b"ping")
    after = ep.poll(0.1)
    got_c = any(fd == c.fileno() for fd, _ in after)
    after_w = sum(1 for fd, _ in ep.poll(0.1) if fd == w)
    early.close()
    cli.close()
    c.close()
    ep.close()
    for fd in (w, r, wr):
        os.close(fd)
    return (f"{order:13s} {' '.join(log)}; before the listener closes: W events {win_w}, accept on W {acc}; "
            f"after: new connection {refused}, open connection readable {got_c}, W events {after_w}")


if __name__ == "__main__":
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    print("kernel", os.uname().release, "cpus", os.cpu_count())
    for mode in ("plain", "rotate", "rotate-cap1"):
        print(f"backlog {mode:12s} 16 queued, then 4 workers poll: {[run('backlog', mode) for _ in range(runs)]}")
    for mode in ("plain", "exclusive", "rotate"):
        print(f"burst   {mode:12s} 64 opened by 4 threads at once: {[run('burst', mode) for _ in range(runs)]}")
    for order in ("park,DEL,ADD", "DEL,park,ADD", "DEL,ADD,park"):
        print("stop   ", stop_order(order))
