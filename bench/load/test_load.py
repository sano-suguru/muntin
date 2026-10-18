"""Checks that bench/load/load.c counts what a server sends: each case serves
one kind of answer, well formed or broken, over HTTP/1.1 or h2c, and the
client must put every measured request in the outcome the case names (and,
for the broken ones, give the reason it names). Python standard library
only; Linux only, like the client. scripts/bench_load.sh runs it before
measuring, so a client that stops seeing a broken answer stops the run.

    python3 bench/load/test_load.py [LOAD_BINARY]

Without LOAD_BINARY it builds the client with `cc` into a temporary
directory.
"""

import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def recv_head(conn, data):
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(65536)
        if not chunk:
            return None, b""
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    return head, rest


def response(body, extra=b"", status=b"200 OK"):
    return b"HTTP/1.1 " + status + b"\r\nContent-Length: " + str(len(body)).encode() + b"\r\n" + extra + b"\r\n" + body


def reset(conn):
    conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    conn.close()


# HTTP/1.1 cases: what the server writes for each request, or how it ends
# the connection. The expected body is `ok`.
H1 = {
    "ok": lambda conn: conn.sendall(response(b"ok")),
    "ok-list-length": lambda conn: conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2, 2\r\nX-Pad:\tv\r\n\r\nok"),
    "ok-split": lambda conn: [conn.sendall(response(b"ok")[:9]), time.sleep(0.002), conn.sendall(response(b"ok")[9:])],
    "status-404": lambda conn: conn.sendall(response(b"no", status=b"404 Not Found")),
    "short-body": lambda conn: [conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nok"), conn.close()],
    "wrong-body": lambda conn: conn.sendall(response(b"no")),
    "extra-bytes": lambda conn: conn.sendall(response(b"ok") + b"x"),
    "no-length": lambda conn: [conn.sendall(b"HTTP/1.1 200 OK\r\n\r\nok"), conn.close()],
    "two-lengths": lambda conn: conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nok"),
    "chunked": lambda conn: conn.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n"),
    "bad-status-line": lambda conn: conn.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok"),
    "bare-lf": lambda conn: conn.sendall(b"HTTP/1.1 200 OK\nContent-Length: 2\r\n\r\nok"),
    "space-before-colon": lambda conn: conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length : 2\r\n\r\nok"),
    "obs-fold": lambda conn: conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n x\r\n\r\nok"),
    "interim": lambda conn: conn.sendall(b"HTTP/1.1 100 Continue\r\n\r\n" + response(b"ok")),
    "close": lambda conn: conn.close(),
    "reset": reset,
    "reset-mid-body": lambda conn: [conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\no"), reset(conn)],
    "silent": lambda conn: time.sleep(1.0),
    "no-required": lambda conn: conn.sendall(response(b"ok")),
}


def h1_serve(conn, mode):
    data = b""
    with conn:
        while True:
            head, data = recv_head(conn, data)
            if head is None:
                return
            if mode == "silent":
                time.sleep(1.0)
                return
            H1[mode](conn)
            if mode in ("close", "reset", "short-body", "reset-mid-body", "no-length"):
                return
            try:
                conn.getpeername()
            except OSError:
                return


# ---- h2c ----


def frame(kind, flags, sid, payload=b""):
    return struct.pack(">I", len(payload))[1:] + bytes([kind, flags]) + struct.pack(">I", sid) + payload


def lit(name, value, indexing=False, huffman=False):
    """A literal field with a new name (RFC 7541 6.2.1, 6.2.2); `huffman`
    sets the H bit on the value (its bytes are then not Huffman, which the
    client never decodes anyway)."""
    out = bytes([0x40 if indexing else 0x00, len(name)]) + name
    return out + bytes([(0x80 if huffman else 0) | len(value)]) + value


def block(status=b"200", length=b"2", extra=b""):
    out = bytes([0x88]) if status == b"200" else lit(b":status", status)  # 0x88: :status 200
    if length is not None:
        out += lit(b"content-length", length)
    return out + extra


class H2Server:
    """Answers every request stream as `mode` says."""

    def __init__(self, conn, mode):
        self.conn, self.mode, self.data = conn, mode, b""

    def read(self, n):
        while len(self.data) < n:
            chunk = self.conn.recv(65536)
            if not chunk:
                raise EOFError
            self.data += chunk
        out, self.data = self.data[:n], self.data[n:]
        return out

    def serve(self):
        with self.conn:
            try:
                if self.read(24) != b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":
                    return
                self.conn.sendall(frame(4, 0, 0))
                indexed = False
                while True:
                    head = self.read(9)
                    length = int.from_bytes(head[:3], "big")
                    kind, flags, sid = head[3], head[4], int.from_bytes(head[5:9], "big") & 0x7FFFFFFF
                    self.read(length)
                    if kind == 4 and not flags & 1:
                        self.conn.sendall(frame(4, 1, 0))
                    if kind == 1 and flags & 1:  # a whole GET
                        if not self.answer(sid, indexed):
                            # Close after reading what the client sent, so
                            # that the close is a FIN, not a reset.
                            self.conn.shutdown(socket.SHUT_WR)
                            self.conn.settimeout(0.5)
                            while self.conn.recv(65536):
                                pass
                            return
                        indexed = True
            except (EOFError, OSError):
                return

    def answer(self, sid, indexed):
        m, send = self.mode, self.conn.sendall
        if m == "ok":
            send(frame(1, 4, sid, block()) + frame(0, 1, sid, b"ok"))
        elif m == "ok-dynamic-table":  # the first answer indexes a field, later ones refer to it
            extra = bytes([0xBE]) if indexed else lit(b"x-one", b"1", indexing=True)
            send(frame(1, 4, sid, block(extra=extra)) + frame(0, 1, sid, b"ok"))
        elif m == "ok-continuation":
            b = block()
            send(frame(1, 0, sid, b[:2]) + frame(9, 4, sid, b[2:]) + frame(0, 0, sid, b"o") + frame(0, 1, sid, b"k"))
        elif m == "ok-padded":
            send(frame(1, 4, sid, block()) + frame(0, 0x9, sid, bytes([3]) + b"ok" + b"\0\0\0"))
        elif m == "ok-ping":
            send(frame(6, 0, 0, b"12345678") + frame(1, 4, sid, block()) + frame(0, 1, sid, b"ok"))
        elif m == "status-404":
            send(frame(1, 4, sid, block(status=b"404")) + frame(0, 1, sid, b"no"))
        elif m == "wrong-body":
            send(frame(1, 4, sid, block()) + frame(0, 1, sid, b"no"))
        elif m == "length-mismatch":
            send(frame(1, 4, sid, block(length=b"3")) + frame(0, 1, sid, b"ok"))
        elif m == "huffman":
            send(frame(1, 4, sid, block(extra=lit(b"x-h", b"1", huffman=True))) + frame(0, 1, sid, b"ok"))
        elif m == "uppercase-name":
            send(frame(1, 4, sid, block(extra=lit(b"X-Up", b"1"))) + frame(0, 1, sid, b"ok"))
        elif m == "connection-field":
            send(frame(1, 4, sid, block(extra=lit(b"connection", b"close"))) + frame(0, 1, sid, b"ok"))
        elif m == "no-status":
            send(frame(1, 4, sid, lit(b"content-length", b"2")) + frame(0, 1, sid, b"ok"))
        elif m == "trailers":
            send(frame(1, 4, sid, block()) + frame(0, 0, sid, b"ok") + frame(1, 5, sid, lit(b"x-t", b"1")))
        elif m == "push":
            send(frame(5, 4, sid, struct.pack(">I", 2) + bytes([0x82, 0x86, 0x84])))
        elif m == "big-frame":
            send(frame(1, 4, sid, block(length=b"20000")) + frame(0, 1, sid, b"x" * 20000))
        elif m == "rst":
            send(frame(3, 0, sid, struct.pack(">I", 2)))
        elif m == "goaway":
            send(frame(7, 0, 0, struct.pack(">II", 0, 0)))
        elif m == "close-mid-body":
            send(frame(1, 4, sid, block()) + frame(0, 0, sid, b"o"))
            return False
        elif m == "close":
            return False
        elif m == "silent":
            pass
        return True


# (case, proto, outcome every measured request must have, reason text, extra client arguments)
CASES = [(f"h1 {m}", "h1", m) for m in H1] + [
    (f"h2c {m}", "h2c", m)
    for m in [
        "ok", "ok-dynamic-table", "ok-continuation", "ok-padded", "ok-ping", "status-404", "wrong-body",
        "length-mismatch", "huffman", "uppercase-name", "connection-field", "no-status", "trailers", "push",
        "big-frame", "rst", "goaway", "close-mid-body", "close", "silent",
    ]
]
EXPECT = {
    "ok": ("ok", None), "ok-list-length": ("ok", None), "ok-split": ("ok", None),
    "ok-dynamic-table": ("ok", None), "ok-continuation": ("ok", None), "ok-padded": ("ok", None),
    "ok-ping": ("ok", None),
    "status-404": ("status", None),
    "short-body": ("invalid", "in_the_middle_of_a_response"),
    "wrong-body": ("invalid", "a_body_other_than_the_expected_one"),
    "extra-bytes": ("invalid", "bytes_after_the_body"),
    "no-length": ("invalid", "no_Content-Length"),
    "two-lengths": ("invalid", "Content-Length_values_that_differ"),
    "chunked": ("invalid", "Transfer-Encoding"),
    "bad-status-line": ("invalid", "status_line"),
    "bare-lf": ("invalid", "a_bare_CR_or_LF"),
    "space-before-colon": ("invalid", "not_a_token"),
    "obs-fold": ("invalid", "obs-fold"),
    "interim": ("invalid", "an_interim_response"),
    "close": ("disconnected", "closed"),
    "reset": ("disconnected", "reset"),
    "reset-mid-body": ("invalid", "in_the_middle_of_a_response"),
    "silent": ("timeout", None),
    "no-required": ("invalid", "without_the_required_header"),
    "length-mismatch": ("invalid", "content-length_other_than_the_DATA"),
    "huffman": ("invalid", "Huffman"),
    "uppercase-name": ("invalid", "lowercase_token"),
    "connection-field": ("invalid", "connection-specific"),
    "no-status": ("invalid", "no_:status"),
    "trailers": ("invalid", "trailers"),
    "push": ("invalid", "PUSH_PROMISE"),
    "big-frame": ("invalid", "a_frame_over_16384_bytes"),
    "rst": ("disconnected", "RST_STREAM_2"),
    "goaway": ("disconnected", "refused_by_GOAWAY"),
    "close-mid-body": ("invalid", "in_the_middle_of_a_response"),
}
OUTCOMES = ["ok", "status", "invalid", "disconnected", "timeout"]


def serve(proto, mode):
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(64)

    def accept():
        while True:
            try:
                conn, _ = listener.accept()
            except OSError:
                return
            target = h1_serve if proto == "h1" else (lambda c, m: H2Server(c, m).serve())
            threading.Thread(target=target, args=(conn, mode), daemon=True).start()

    threading.Thread(target=accept, daemon=True).start()
    return listener


def run(load, proto, mode):
    listener = serve(proto, mode)
    args = [load, "--port", str(listener.getsockname()[1]), "--proto", proto, "--conns", "1",
            "--warmup", "0", "--duration", "0.3", "--timeout", "300", "--path", "/", "--expect-text", "ok"]
    if mode == "no-required":
        args += ["--require-header", "x-need: 1"]
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=30)
    finally:
        listener.close()
    if out.returncode != 0:
        raise AssertionError(f"exit {out.returncode}: {out.stderr}")
    return dict(f.split("=", 1) for f in out.stdout.split())


def main():
    if sys.platform != "linux":
        print("test_load.py: skipped, the client is Linux only")
        return 0
    with tempfile.TemporaryDirectory() as tmp:
        load = sys.argv[1] if len(sys.argv) > 1 else os.path.join(tmp, "load")
        if len(sys.argv) <= 1:
            subprocess.run(["cc", "-O2", "-Wall", "-Werror", "-pthread", "-o", load, os.path.join(HERE, "load.c")],
                           check=True)
        failures = 0
        for name, proto, mode in CASES:
            want, why = EXPECT.get(mode, ("ok", None))
            try:
                f = run(load, proto, mode)
                sent = int(f["sent"])
                counts = {o: int(f[o]) for o in OUTCOMES}
                if sent == 0:
                    raise AssertionError("no request sent")
                if sum(counts.values()) != sent:
                    raise AssertionError(f"outcomes {counts} do not add up to sent={sent}")
                if counts[want] != sent:
                    raise AssertionError(f"want every request {want}: {counts}")
                reasons = f["invalid_as"] + " " + f["disconnected_as"]
                if why and why not in reasons:
                    raise AssertionError(f"want the reason {why!r}: {reasons}")
                print(f"ok   {name}: {sent} {want}")
            except AssertionError as e:
                failures += 1
                print(f"FAIL {name}: {e}")
        print(f"test_load.py: {len(CASES) - failures} passed, {failures} failed")
        return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
