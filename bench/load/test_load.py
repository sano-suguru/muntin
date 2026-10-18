"""Checks that bench/load/load.c counts what a server sends: each case serves
one kind of answer, well formed or broken, over HTTP/1.1 or h2c, and the
client must put every measured request in the outcome the case names (and,
for the broken ones, give the reason it names). Some cases run several
connections, threads and h2c streams at once, with answers interleaved, and
POST a 300 KiB body that the server echoes, so that h2c flow control in both
directions is exercised. Python standard library only; Linux only, like the
client. scripts/bench_load.sh runs it before measuring, so a client that
stops seeing a broken answer stops the run.

    python3 bench/load/test_load.py [LOAD_BINARY]

Without LOAD_BINARY it builds the client with `cc` and AddressSanitizer and
UndefinedBehaviorSanitizer into a temporary directory; a report from either
ends the client with a nonzero status, which fails the case (leak checking
is off: the client keeps its tables until it exits).
"""

import os
import select
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BODY = bytes((i * 7 + i // 251) % 256 for i in range(300 * 1024))


def recv_request(conn, data):
    """(head, body, rest) of the next request on conn, or (None, b"", b"")."""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(65536)
        if not chunk:
            return None, b"", b""
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    length = 0
    for line in head.split(b"\r\n")[1:]:
        name, _, value = line.partition(b":")
        if name.strip().lower() == b"content-length":
            length = int(value)
    while len(rest) < length:
        chunk = conn.recv(65536)
        if not chunk:
            return None, b"", b""
        rest += chunk
    return head, rest[:length], rest[length:]


def response(body, extra=b"", status=b"200 OK"):
    return b"HTTP/1.1 " + status + b"\r\nContent-Length: " + str(len(body)).encode() + b"\r\n" + extra + b"\r\n" + body


def reset(conn):
    conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    conn.close()


# HTTP/1.1 cases: what the server writes for each request (given its body),
# or how it ends the connection. The expected body is `ok`, or for a POST
# the request's.
H1 = {
    "ok": lambda conn: conn.sendall(response(b"ok")),
    "ok-many": lambda conn: conn.sendall(response(b"ok")),
    "ok-empty-reason": lambda conn: conn.sendall(b"HTTP/1.1 200 \r\nContent-Length: 2\r\n\r\nok"),
    "status-no-reason-sp": lambda conn: conn.sendall(b"HTTP/1.1 200\r\nContent-Length: 2\r\n\r\nok"),
    "ctl-in-value": lambda conn: conn.sendall(response(b"ok", extra=b"X-A: a\x01b\r\n")),
    "del-in-reason": lambda conn: conn.sendall(b"HTTP/1.1 200 O\x7fK\r\nContent-Length: 2\r\n\r\nok"),
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
            head, body, data = recv_request(conn, data)
            if head is None:
                return
            if mode == "silent":
                time.sleep(1.0)
                return
            if mode == "ok-post-echo":
                conn.sendall(response(body))
                continue
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
    """Answers every request stream as `mode` says, once the request is whole
    (its HEADERS, or its last DATA, carries END_STREAM). It acknowledges
    request DATA with WINDOW_UPDATEs and leaves its own receive windows at
    the default 65,535, so a client that ignores flow control stalls."""

    def __init__(self, conn, mode):
        self.conn, self.mode, self.data = conn, mode, b""
        self.bodies = {}  # request bodies of streams not yet whole
        self.pending = []  # whole requests not yet answered: (sid, body)
        self.answered = 0

    def read(self, n):
        while len(self.data) < n:
            chunk = self.conn.recv(65536)
            if not chunk:
                raise EOFError
            self.data += chunk
        out, self.data = self.data[:n], self.data[n:]
        return out

    def idle(self, wait):
        """Whether no further frame is already here or arrives within `wait` s."""
        if len(self.data) >= 9:
            return False
        return not select.select([self.conn], [], [], wait)[0]

    def serve(self):
        with self.conn:
            try:
                if self.read(24) != b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":
                    return
                self.conn.sendall(frame(4, 0, 0))
                while True:
                    head = self.read(9)
                    length = int.from_bytes(head[:3], "big")
                    kind, flags, sid = head[3], head[4], int.from_bytes(head[5:9], "big") & 0x7FFFFFFF
                    payload = self.read(length)
                    if kind == 4 and not flags & 1:
                        self.conn.sendall(frame(4, 1, 0))
                    elif kind == 1:
                        if flags & 1:
                            self.pending.append((sid, b""))
                        else:
                            self.bodies[sid] = b""
                    elif kind == 0 and sid in self.bodies:
                        self.bodies[sid] += payload
                        if payload:
                            inc = struct.pack(">I", len(payload))
                            self.conn.sendall(frame(8, 0, 0, inc) + frame(8, 0, sid, inc))
                        if flags & 1:
                            self.pending.append((sid, self.bodies.pop(sid)))
                    wait = 0.005 if self.mode == "ok-interleaved" else 0
                    if self.pending and self.idle(wait):
                        if not self.answer_pending():
                            # Close after reading what the client sent, so
                            # that the close is a FIN, not a reset.
                            self.conn.shutdown(socket.SHUT_WR)
                            self.conn.settimeout(0.5)
                            while self.conn.recv(65536):
                                pass
                            return
            except (EOFError, OSError):
                return

    def answer_pending(self):
        pending, self.pending = self.pending, []
        if self.mode == "ok-interleaved":  # every head, then each body in two parts, newest stream first
            pending.reverse()
            self.conn.sendall(b"".join(frame(1, 4, sid, block()) for sid, _ in pending)
                              + b"".join(frame(0, 0, sid, b"o") for sid, _ in pending)
                              + b"".join(frame(0, 1, sid, b"k") for sid, _ in pending))
            return True
        for sid, body in pending:
            if not self.answer(sid, body):
                return False
            self.answered += 1
        return True

    def answer(self, sid, body):
        m, send, first = self.mode, self.conn.sendall, self.answered == 0
        ok = frame(1, 4, sid, block()) + frame(0, 1, sid, b"ok")
        if m == "ok":
            send(ok)
        elif m == "ok-post-echo":
            out = frame(1, 4, sid, block(length=str(len(body)).encode()))
            for i in range(0, len(body), 16384):
                out += frame(0, 1 if i + 16384 >= len(body) else 0, sid, body[i : i + 16384])
            send(out)
        elif m == "ok-dynamic-table":  # the first answer indexes a field, later ones refer to it
            extra = lit(b"x-one", b"1", indexing=True) if first else bytes([0xBE])
            send(frame(1, 4, sid, block(extra=extra)) + frame(0, 1, sid, b"ok"))
        elif m == "ok-dynamic-name":
            # The first answer indexes two fields; every later one indexes a
            # new field named by the entry at index 63 (RFC 7541 6.2.1), so
            # the table grows, is reallocated and evicts while a name taken
            # from it is being inserted.
            if first:
                extra = lit(b"x-one", b"1", indexing=True) + lit(b"x-two", b"2", indexing=True)
            else:
                extra = bytes([0x7F, 0x00, 0x01]) + b"v"
            send(frame(1, 4, sid, block(extra=extra)) + frame(0, 1, sid, b"ok"))
        elif m == "ok-continuation":
            b = block()
            send(frame(1, 0, sid, b[:2]) + frame(9, 4, sid, b[2:]) + frame(0, 0, sid, b"o") + frame(0, 1, sid, b"k"))
        elif m == "ok-padded":
            send(frame(1, 4, sid, block()) + frame(0, 0x9, sid, bytes([3]) + b"ok" + b"\0\0\0"))
        elif m == "ok-ping":
            send(frame(6, 0, 0, b"12345678") + ok)
        elif m == "ok-rst-after-end":  # RST_STREAM NO_ERROR after a whole answer is allowed
            send(ok + frame(3, 0, sid, struct.pack(">I", 0)))
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
        elif m == "ctl-in-value":
            send(frame(1, 4, sid, block(extra=lit(b"x-c", b"a\x01b"))) + frame(0, 1, sid, b"ok"))
        elif m == "no-status":
            send(frame(1, 4, sid, lit(b"content-length", b"2")) + frame(0, 1, sid, b"ok"))
        elif m == "trailers":
            send(frame(1, 4, sid, block()) + frame(0, 0, sid, b"ok") + frame(1, 5, sid, lit(b"x-t", b"1")))
        elif m == "data-after-end":
            send(ok + frame(0, 0, sid, b"CORRUPTION"))
        elif m == "headers-after-end":
            send(ok + frame(1, 4, sid, block()))
        elif m == "wu-zero-conn":
            send(frame(8, 0, 0, struct.pack(">I", 0)) + ok)
        elif m == "wu-zero-stream":
            send(frame(8, 0, sid, struct.pack(">I", 0)) + ok)
        elif m == "wu-overflow":
            send(frame(8, 0, 0, struct.pack(">I", 0x7FFFFFFF)) + ok)
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


MANY = ["--conns", "4", "--threads", "2"]
MUX = ["--conns", "2", "--streams", "8", "--threads", "2"]
POST = ["--method", "POST", "--body", "BODY", "--expect", "BODY"]

# (proto, mode, the outcome every measured request must have, the reason it
# must give, extra client arguments, other fields that must hold)
CASES = [
    ("h1", "ok", "ok", None, [], None),
    ("h1", "ok-many", "ok", None, MANY, None),
    ("h1", "ok-post-echo", "ok", None, MANY + POST, None),
    ("h1", "ok-list-length", "ok", None, [], None),
    ("h1", "ok-split", "ok", None, [], None),
    ("h1", "ok-empty-reason", "ok", None, [], None),
    ("h1", "status-404", "status", None, [], None),
    ("h1", "short-body", "invalid", "in_the_middle_of_a_response", [], None),
    ("h1", "wrong-body", "invalid", "a_body_other_than_the_expected_one", [], None),
    ("h1", "extra-bytes", "invalid", "bytes_after_the_body", [], None),
    ("h1", "no-length", "invalid", "no_Content-Length", [], None),
    ("h1", "two-lengths", "invalid", "Content-Length_values_that_differ", [], None),
    ("h1", "chunked", "invalid", "Transfer-Encoding", [], None),
    ("h1", "bad-status-line", "invalid", "status_line", [], None),
    ("h1", "status-no-reason-sp", "invalid", "status_line", [], None),
    ("h1", "del-in-reason", "invalid", "status_line", [], None),
    ("h1", "ctl-in-value", "invalid", "a_control_character_in_a_field_value", [], None),
    ("h1", "bare-lf", "invalid", "a_bare_CR_or_LF", [], None),
    ("h1", "space-before-colon", "invalid", "not_a_token", [], None),
    ("h1", "obs-fold", "invalid", "obs-fold", [], None),
    ("h1", "interim", "invalid", "an_interim_response", [], None),
    ("h1", "close", "disconnected", "closed", [], None),
    ("h1", "reset", "disconnected", "reset", [], None),
    ("h1", "reset-mid-body", "invalid", "in_the_middle_of_a_response", [], None),
    ("h1", "silent", "timeout", None, [], None),
    ("h1", "no-required", "invalid", "without_the_required_header", ["--require-header", "x-need: 1"], None),
    ("h2c", "ok", "ok", None, [], None),
    ("h2c", "ok-interleaved", "ok", None, MUX, None),
    ("h2c", "ok-post-echo", "ok", None, MUX + POST, None),
    ("h2c", "ok-dynamic-table", "ok", None, [], None),
    ("h2c", "ok-dynamic-name", "ok", None, [], None),
    ("h2c", "ok-continuation", "ok", None, [], None),
    ("h2c", "ok-padded", "ok", None, [], None),
    ("h2c", "ok-ping", "ok", None, [], None),
    ("h2c", "ok-rst-after-end", "ok", None, [], None),
    ("h2c", "status-404", "status", None, [], None),
    ("h2c", "wrong-body", "invalid", "a_body_other_than_the_expected_one", [], None),
    ("h2c", "length-mismatch", "invalid", "content-length_other_than_the_DATA", [], None),
    ("h2c", "huffman", "invalid", "Huffman", [], None),
    ("h2c", "uppercase-name", "invalid", "lowercase_token", [], None),
    ("h2c", "connection-field", "invalid", "connection-specific", [], None),
    ("h2c", "ctl-in-value", "invalid", "a_control_character_in_a_field_value", [], None),
    ("h2c", "no-status", "invalid", "no_:status", [], None),
    ("h2c", "trailers", "invalid", "trailers", [], None),
    # The answer before the extra frame is whole, so the request is ok; the
    # extra frame is counted apart, once per connection it breaks.
    ("h2c", "data-after-end", "ok", None, [], "after_end"),
    ("h2c", "headers-after-end", "ok", None, [], "after_end"),
    ("h2c", "wu-zero-conn", "invalid", "a_WINDOW_UPDATE_of_0_on_the_connection", [], None),
    ("h2c", "wu-zero-stream", "invalid", "a_WINDOW_UPDATE_of_0_on_its_stream", [], None),
    ("h2c", "wu-overflow", "invalid", "a_connection_flow-control_window_over", [], None),
    ("h2c", "push", "invalid", "PUSH_PROMISE", [], None),
    ("h2c", "big-frame", "invalid", "a_frame_over_16384_bytes", [], None),
    ("h2c", "rst", "disconnected", "RST_STREAM_2", [], None),
    ("h2c", "goaway", "disconnected", "refused_by_GOAWAY", [], None),
    ("h2c", "close-mid-body", "invalid", "in_the_middle_of_a_response", [], None),
    ("h2c", "close", "disconnected", "closed", [], None),
    ("h2c", "silent", "timeout", None, [], None),
]
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


def run(load, proto, mode, extra, body_file):
    listener = serve(proto, mode)
    args = [load, "--port", str(listener.getsockname()[1]), "--proto", proto, "--warmup", "0",
            "--duration", "0.3", "--timeout", "300", "--path", "/"]
    if "--conns" not in extra:
        args += ["--conns", "1"]
    if "--expect" not in extra:
        args += ["--expect-text", "ok"]
    args += [body_file if a == "BODY" else a for a in extra]
    try:
        # The client keeps its tables until it exits; leaks are not what this checks.
        env = dict(os.environ, ASAN_OPTIONS="detect_leaks=0")
        out = subprocess.run(args, capture_output=True, text=True, timeout=30, env=env)
    finally:
        listener.close()
    if out.returncode != 0:
        raise AssertionError(f"exit {out.returncode}: {out.stderr[-2000:]}")
    return dict(f.split("=", 1) for f in out.stdout.split())


def main():
    if sys.platform != "linux":
        print("test_load.py: skipped, the client is Linux only")
        return 0
    with tempfile.TemporaryDirectory() as tmp:
        load = sys.argv[1] if len(sys.argv) > 1 else os.path.join(tmp, "load")
        if len(sys.argv) <= 1:
            subprocess.run(["cc", "-O1", "-g", "-Wall", "-Werror", "-pthread", "-fno-omit-frame-pointer",
                            "-fsanitize=address,undefined", "-fno-sanitize-recover=all", "-o", load,
                            os.path.join(HERE, "load.c")], check=True)
        body_file = os.path.join(tmp, "body")
        with open(body_file, "wb") as f:
            f.write(BODY)
        failures = 0
        for proto, mode, want, why, extra, field in CASES:
            name = f"{proto} {mode}"
            try:
                f = run(load, proto, mode, extra, body_file)
                sent = int(f["sent"])
                counts = {o: int(f[o]) for o in OUTCOMES}
                if sent == 0:
                    raise AssertionError("no request sent")
                if sum(counts.values()) != sent:
                    raise AssertionError(f"outcomes {counts} do not add up to sent={sent}")
                if counts[want] != sent:
                    raise AssertionError(f"want every request {want}: {counts} {f['invalid_as']}")
                reasons = f["invalid_as"] + " " + f["disconnected_as"]
                if why and why not in reasons:
                    raise AssertionError(f"want the reason {why!r}: {reasons}")
                anomalies = {k: int(f[k]) for k in ("stray", "after_end")}
                if field:
                    if anomalies[field] == 0:
                        raise AssertionError(f"want {field} counted: {anomalies}")
                elif any(anomalies.values()):
                    raise AssertionError(f"want no stray bytes or late frames: {anomalies}")
                print(f"ok   {name}: {sent} {want}" + (f", {field}={f[field]}" if field else ""))
            except AssertionError as e:
                failures += 1
                print(f"FAIL {name}: {e}")
        print(f"test_load.py: {len(CASES) - failures} passed, {failures} failed")
        return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
