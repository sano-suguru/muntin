"""Linux kernel probes for the worker-spread decision (M3-068).

shared: one listener, N threads each with its own epoll, the listener
registered EPOLLIN|EPOLLEXCLUSIVE level-triggered, accept until EAGAIN: a
working exclusive registration without re-registration, which stock Flare
v0.12.0 never reaches (its EPOLLRDHUP makes the kernel refuse the flag, and
it falls back to a plain registration). rotate: the same, but a
worker re-registers the listener (DEL then ADD) after each accept batch.
reuseport: one SO_REUSEPORT listener per worker. Client opens K connections
one after another, each kept open after its accept is seen; counts are per
worker, busiest first, every worker listed. A worker that fails to register
or fails later, or a connection no worker accepted once the hold ends, ends
the probe with an error (exit 1). A held worker stands for one running a
handler: the client opens nothing until that worker has said it is out of
its poll and will not poll again while held.
"""
import errno, os, select, socket, sys, threading, time
from collections import Counter

EPOLLEXCLUSIVE = getattr(select, "EPOLLEXCLUSIVE", 1 << 28)


def worker(idx, lfd_sock, mode, owner, stop, held, parked, ready, errors):
    """Runs one worker; any exception, its registration's included, goes to
    `errors` for `run` to fail on."""
    try:
        ep = select.epoll()
        flags = select.EPOLLIN | EPOLLEXCLUSIVE
        ep.register(lfd_sock.fileno(), flags)
        ready.release()
        conns = []
        while not stop.is_set():
            if held.get(idx):
                parked.set()
                time.sleep(0.005)
                continue
            for fd, ev in ep.poll(0.05):
                n = 0
                while True:
                    try:
                        c, _ = lfd_sock.accept()
                    except BlockingIOError:
                        break
                    conns.append(c)
                    owner[c.getpeername()[1]] = idx
                    n += 1
                if mode == "rotate" and n:
                    ep.unregister(lfd_sock.fileno())
                    ep.register(lfd_sock.fileno(), flags)
        ep.close()
        for c in conns:
            c.close()
    except BaseException as e:
        errors.append(f"worker {idx}: {e!r}")


def run(mode, workers, k, held_worker=None):
    stop = threading.Event()
    owner = {}
    held = {}
    parked = threading.Event()
    ready, errors = threading.Semaphore(0), []
    listeners = []
    if mode == "reuseport":
        port = 0
        for i in range(workers):
            s = socket.socket()
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            s.bind(("127.0.0.1", port))
            port = s.getsockname()[1]
            s.listen(128)
            s.setblocking(False)
            listeners.append(s)
    else:
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        s.listen(128)
        s.setblocking(False)
        port = s.getsockname()[1]
        listeners = [s] * workers
    threads = [
        threading.Thread(target=worker, args=(i, listeners[i], mode, owner, stop, held, parked, ready, errors), daemon=True)
        for i in range(workers)
    ]
    for t in threads:
        t.start()
    for _ in range(workers):
        if not ready.acquire(timeout=2) or errors:
            raise RuntimeError(f"{mode}: a worker did not start: {errors}")
    time.sleep(0.05)
    if held_worker is not None:
        held[held_worker] = True
        if not parked.wait(1):
            raise RuntimeError(f"worker {held_worker} did not leave its poll")
    clients = []
    for _ in range(k):
        c = socket.create_connection(("127.0.0.1", port))
        lp = c.getsockname()[1]
        t0 = time.monotonic()
        while lp not in owner and time.monotonic() - t0 < 0.2:
            time.sleep(0.0005)
        clients.append((c, lp))
    waiting = sum(1 for _, lp in clients if lp not in owner)
    if held_worker is not None and any(owner.get(lp) == held_worker for _, lp in clients):
        raise RuntimeError(f"held worker {held_worker} accepted a connection")
    held.clear()
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline and not all(lp in owner for _, lp in clients):
        time.sleep(0.005)
    stop.set()
    for t in threads:
        t.join(2)
    for c, _ in clients:
        c.close()
    for s in set(listeners):
        s.close()
    if errors or any(t.is_alive() for t in threads):
        raise RuntimeError(f"{mode}: a worker failed: {errors or 'did not stop'}")
    missing = sum(1 for _, lp in clients if lp not in owner)
    if missing:
        raise RuntimeError(f"{mode}: {missing} of {k} connections never accepted")
    counts = Counter(owner[lp] for _, lp in clients)
    return sorted((counts.get(i, 0) for i in range(workers)), reverse=True), waiting


if __name__ == "__main__":
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    print("kernel", os.uname().release, "cpus", os.cpu_count())
    for mode in ("shared", "rotate", "reuseport"):
        spreads = [run(mode, 4, 16)[0] for _ in range(runs)]
        print(f"{mode:10s} 16 sequential over 4 workers, per worker busiest first: {spreads}")
    for mode in ("shared", "rotate", "reuseport"):
        res = [run(mode, 4, 16, held_worker=0)[1] for _ in range(runs)]
        print(f"{mode:10s} worker 0 held (not polling): new connections not accepted within 200 ms of 16: {res}")
