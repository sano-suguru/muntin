"""Connection churn against a running hol server (M3-068, review of #120).

churn.py PORT PID SECONDS THREADS: each thread opens a connection, sends
`GET /health` with `Connection: close`, reads the answer to EOF and closes,
in a loop. Prints connections per second, p50/p99 of connect-to-EOF in ms,
and the server's CPU seconds (utime + stime) per 1000 connections. The
client shares the machine's CPUs with the server: compare runs, not
absolute numbers.
"""
import os, socket, sys, threading, time

port, pid, seconds, threads = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
REQ = b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
tick = os.sysconf("SC_CLK_TCK")


def cpu():
    with open(f"/proc/{pid}/stat") as f:
        parts = f.read().rsplit(")", 1)[1].split()
    return (int(parts[11]) + int(parts[12])) / tick


lat, errors, lock = [], [0], threading.Lock()
end = time.monotonic() + seconds


def run():
    mine, bad = [], 0
    while time.monotonic() < end:
        t0 = time.monotonic()
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=5)
            s.sendall(REQ)
            data = b""
            while True:
                b = s.recv(4096)
                if not b:
                    break
                data += b
            s.close()
            if not data.startswith(b"HTTP/1.1 200"):
                bad += 1
                continue
        except OSError:
            bad += 1
            continue
        mine.append(time.monotonic() - t0)
    with lock:
        lat.extend(mine)
        errors[0] += bad


c0 = cpu()
ts = [threading.Thread(target=run) for _ in range(threads)]
for t in ts:
    t.start()
for t in ts:
    t.join()
c1 = cpu()
lat.sort()
n = len(lat)
print(f"conn/s {n / seconds:.0f} p50 {lat[n // 2] * 1000:.2f} ms p99 {lat[int(n * 0.99)] * 1000:.2f} ms "
      f"server cpu s/1000 conn {(c1 - c0) / n * 1000:.3f} errors {errors[0]}")
