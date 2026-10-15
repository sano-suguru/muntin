"""Linux kernel probes for the worker-spread decision (M3-068).

shared: one listener, N threads each with its own epoll, the listener
registered EPOLLIN|EPOLLEXCLUSIVE level-triggered, accept until EAGAIN
(Flare v0.12.0's shared-listener worker loop). rotate: the same, but a
worker re-registers the listener (DEL then ADD) after each accept batch.
reuseport: one SO_REUSEPORT listener per worker. Client opens K connections
one after another, each kept open after its accept is seen.
"""
import errno, os, select, socket, sys, threading, time
from collections import Counter

EPOLLEXCLUSIVE = getattr(select, "EPOLLEXCLUSIVE", 1 << 28)


def worker(idx, lfd_sock, mode, owner, stop, held):
    ep = select.epoll()
    flags = select.EPOLLIN | EPOLLEXCLUSIVE
    ep.register(lfd_sock.fileno(), flags)
    conns = []
    while not stop.is_set():
        if held.get(idx):
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


def run(mode, workers, k, held_worker=None):
    stop = threading.Event()
    owner = {}
    held = {}
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
        threading.Thread(target=worker, args=(i, listeners[i], mode, owner, stop, held))
        for i in range(workers)
    ]
    for t in threads:
        t.start()
    time.sleep(0.1)
    if held_worker is not None:
        held[held_worker] = True
    clients = []
    for _ in range(k):
        c = socket.create_connection(("127.0.0.1", port))
        lp = c.getsockname()[1]
        t0 = time.monotonic()
        while lp not in owner and time.monotonic() - t0 < 0.2:
            time.sleep(0.0005)
        clients.append((c, lp))
    waiting = sum(1 for _, lp in clients if lp not in owner)
    held.clear()
    time.sleep(0.1)
    counts = Counter(owner.get(lp, -1) for _, lp in clients)
    stop.set()
    for t in threads:
        t.join()
    for c, _ in clients:
        c.close()
    for s in set(listeners):
        s.close()
    return sorted(counts.values(), reverse=True), waiting


if __name__ == "__main__":
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    print("kernel", os.uname().release, "cpus", os.cpu_count())
    for mode in ("shared", "rotate", "reuseport"):
        spreads = [run(mode, 4, 16)[0] for _ in range(runs)]
        print(f"{mode:10s} 16 sequential over 4 workers, per worker busiest first: {spreads}")
    for mode in ("shared", "rotate", "reuseport"):
        res = [run(mode, 4, 16, held_worker=0)[1] for _ in range(runs)]
        print(f"{mode:10s} worker 0 held (not polling): new connections not accepted within 200 ms of 16: {res}")
