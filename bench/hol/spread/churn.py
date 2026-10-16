"""Connection churn against a running hol server (M3-068).

churn.py PORT PID SECONDS THREADS: each thread opens a connection, sends
`GET /health` with `Connection: close`, reads the answer to EOF and closes,
in a loop, until an absolute deadline. An answer counts as answered only if
it is complete: status line `HTTP/1.1 200`, headers ended, a Content-Length
and exactly that many body bytes, the body `ok`. Prints attempts, answered,
failures by kind, answered connections per second, p50/p99 of connect-to-EOF
over answered connections in ms, and the server's and this client's CPU
seconds (utime + stime) per 1000 attempts. The client shares the machine's
CPUs with the server: compare runs, not absolute numbers. Any exception
during an attempt (a reset, an unreadable Content-Length) fails that attempt,
by its kind; a thread that ends otherwise counts as failed too. Exits 1 if
any attempt or thread failed or none was answered.
"""
import os, socket, sys, threading, time

port, pid, seconds, threads = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
REQ = b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
tick = os.sysconf("SC_CLK_TCK")


def cpu():
    with open(f"/proc/{pid}/stat") as f:
        parts = f.read().rsplit(")", 1)[1].split()
    return (int(parts[11]) + int(parts[12])) / tick


def check(data):
    """Returns None for a complete `200 ok` answer, else the failure kind."""
    head, sep, body = data.partition(b"\r\n\r\n")
    if not sep:
        return "truncated-head"
    lines = head.split(b"\r\n")
    if not lines[0].startswith(b"HTTP/1.1 200 "):
        return "status"
    length = None
    for line in lines[1:]:
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            try:
                length = int(value.strip())
            except ValueError:
                return "bad-length"
    if length is None:
        return "no-length"
    if len(body) != length:
        return "truncated-body"
    return None if body == b"ok" else "body"


lat, fails, lock = [], {}, threading.Lock()
end = time.monotonic() + seconds


def attempt(t0):
    """Returns None for an answered attempt, else the failure kind."""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=max(0.1, end + 5 - t0)) as s:
            s.sendall(REQ)
            data = b""
            while chunk := s.recv(4096):
                data += chunk
        return check(data)
    except Exception as e:
        return type(e).__name__


def run():
    mine, bad = [], {}
    try:
        while time.monotonic() < end:
            t0 = time.monotonic()
            kind = attempt(t0)
            if kind is None:
                mine.append(time.monotonic() - t0)
            else:
                bad[kind] = bad.get(kind, 0) + 1
    except BaseException as e:
        kind = "thread: " + type(e).__name__
        bad[kind] = bad.get(kind, 0) + 1
    finally:
        with lock:
            lat.extend(mine)
            for k, v in bad.items():
                fails[k] = fails.get(k, 0) + v


c0, t0 = cpu(), os.times()
ts = [threading.Thread(target=run) for _ in range(threads)]
for t in ts:
    t.start()
for t in ts:
    t.join()
c1, t1 = cpu(), os.times()
lat.sort()
n, failed = len(lat), sum(fails.values())
attempts = n + failed
client = (t1.user + t1.system) - (t0.user + t0.system)
p50 = f"{lat[n // 2] * 1000:.2f}" if n else "-"
p99 = f"{lat[int(n * 0.99)] * 1000:.2f}" if n else "-"
per = 1000 / attempts if attempts else 0
print(f"attempts {attempts} answered {n} failed {failed} {fails or ''} conn/s {n / seconds:.0f} "
      f"p50 {p50} ms p99 {p99} ms cpu s/1000 attempts server {(c1 - c0) * per:.3f} client {client * per:.3f}")
sys.exit(1 if failed or not n else 0)
