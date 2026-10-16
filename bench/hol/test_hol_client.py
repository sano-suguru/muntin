"""Tests of hol_client.py's response checks (Python standard library only),
against scripted servers on loopback: each response that is not whole
(hol_client.h1_read_response and hol_client.H2c say what that means) must
come out malformed, and a run that gets one must exit 1. scripts/check.sh
runs it.

    python3 -I bench/hol/test_hol_client.py
"""

import os
import socket
import struct
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hol_client  # noqa: E402

OK = {"/health": b"ok", "/worker": b"7"}


def h1_response(body, fields=None):
    if fields is None:
        fields = [b"Content-Length: %d" % len(body)]
    return b"HTTP/1.1 200 OK\r\n" + b"".join(f + b"\r\n" for f in fields) + b"\r\n" + body


def padded_to(size, body):
    """A whole 200 response with `body`, padded to exactly `size` bytes."""
    bare = h1_response(body, [b"Content-Length: %d" % len(body), b"X-Pad: "])
    return h1_response(body, [b"Content-Length: %d" % len(body), b"X-Pad: " + b"a" * (size - len(bare))])


class Server:
    """A loopback listener that serves each connection with `serve(conn)` on
    a thread of its own."""

    def __init__(self, serve):
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(64)
        self.port = self.listener.getsockname()[1]
        self.serve = serve
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while True:
            try:
                conn, _ = self.listener.accept()
            except OSError:
                return
            threading.Thread(target=self.run, args=(conn,), daemon=True).start()

    def run(self, conn):
        try:
            self.serve(conn)
        except OSError:
            pass
        finally:
            conn.close()

    def close(self):
        self.listener.close()


def h1_server(answer):
    """Serves HTTP/1.1 requests one after another on each connection;
    `answer(path)` returns the chunks to send, each bytes, a float (seconds
    to wait) or "close"."""

    def serve(conn):
        data = b""
        while True:
            while b"\r\n\r\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                data += chunk
            head, _, data = data.partition(b"\r\n\r\n")
            path = head.split(b" ")[1].decode()
            close = b"connection: close" in head.lower()
            for part in answer(path):
                if part == "close":
                    return
                if isinstance(part, float):
                    time.sleep(part)
                else:
                    conn.sendall(part)
            if close:
                return

    return Server(serve)


def frame(kind, flags, stream, payload):
    return struct.pack(">I", len(payload))[1:] + bytes([kind, flags]) + struct.pack(">I", stream) + payload


def ok_frames(stream, path):
    return [frame(1, 0x4, stream, b"\x88"), frame(0, 0x1, stream, OK[path])]


def h2_server(answer):
    """Serves prior-knowledge h2c; `answer(stream, path)` returns the frames
    to send for each request (bytes, or "close")."""

    def serve(conn):
        data = b""
        while len(data) < 24:
            data += conn.recv(4096)
        data = data[24:]
        conn.sendall(frame(4, 0, 0, b""))
        while True:
            while len(data) < 9 or len(data) < 9 + struct.unpack(">I", b"\x00" + data[:3])[0]:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                data += chunk
            length = struct.unpack(">I", b"\x00" + data[:3])[0]
            kind, stream = data[3], struct.unpack(">I", data[5:9])[0] & 0x7FFFFFFF
            payload, data = data[9 : 9 + length], data[9 + length :]
            if kind != 1:
                continue
            # hol_client.H2c's block: \x82 \x86 \x04 <length> <path> ...
            for part in answer(stream, payload[4 : 4 + payload[3]].decode()):
                if part == "close":
                    return
                conn.sendall(part)

    return Server(serve)


class H1ReadResponse(unittest.TestCase):
    def outcome(self, answer, path="/health"):
        """h1_new_call's outcome for one request to a server answering with
        `answer`."""
        server = h1_server(lambda p: answer)
        try:
            return hol_client.h1_new_call(server.port, path, 2.0, {})
        finally:
            server.close()

    def assertMalformed(self, outcome):
        self.assertTrue(hol_client.is_malformed(outcome), outcome)

    def test_a_whole_response_is_its_status(self):
        self.assertEqual(self.outcome([h1_response(b"ok")]), 200)

    def test_eof_before_any_byte_is_closed_not_malformed(self):
        self.assertEqual(self.outcome(["close"]), "closed")

    def test_framing_errors_are_malformed(self):
        for answer in (
            [h1_response(b"", [])],  # no Content-Length
            [h1_response(b"ok", [b"Content-Length: 0", b"Content-Length: 2"])],
            [h1_response(b"ok", [b"Content-Length: +2"])],
            [h1_response(b"ok", [b"Content-Length: 2", b"Transfer-Encoding: chunked"])],
            [b"HTTP/1.1 200OK\r\nContent-Length: 2\r\n\r\nok"],
            [b"HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok"],
            [h1_response(b"ok")[:-1], "close"],  # short body
            [h1_response(b"ok")[:10], "close"],  # short head
            [h1_response(b"ok") + b"X"],  # a stray byte in the same write
        ):
            with self.subTest(answer=answer):
                self.assertMalformed(self.outcome(answer))

    def test_a_body_other_than_the_routes_is_malformed(self):
        self.assertMalformed(self.outcome([h1_response(b"no")]))
        self.assertMalformed(self.outcome([h1_response(b"x7")], "/worker"))
        self.assertEqual(self.outcome([h1_response(b"77")], "/worker"), 200)

    def test_a_stray_byte_after_the_first_read_is_malformed(self):
        # #133 review: a whole response of exactly one recv(4096), then a
        # stray byte, which a parser that checks only what it has read misses.
        answer = [padded_to(4096, b"ok"), 0.05, b"X"]
        self.assertEqual(len(answer[0]), 4096)
        self.assertMalformed(self.outcome(answer))
        # On a kept-open connection: at once if the byte is already waiting,
        # else at the next answer on it (or the run's final check).
        server = h1_server(lambda p: [padded_to(4096, b"ok") + b"X"])
        try:
            conn = hol_client.H1(server.port, ask_worker=False)
            with self.assertRaises(hol_client.Malformed):
                conn.call("/health")
        finally:
            server.close()
        server = h1_server(lambda p: answer)
        try:
            conn = hol_client.H1(server.port, ask_worker=False)
            self.assertEqual(conn.call("/health")[0], 200)
            time.sleep(0.2)
            self.assertEqual(hol_client.pending(conn.sock), 1)
            with self.assertRaises(hol_client.Malformed):
                conn.call("/health")
        finally:
            server.close()

    def test_a_close_response_must_be_followed_by_eof(self):
        self.assertMalformed(self.outcome([h1_response(b"ok"), 0.05, b"X", "close"]))
        self.assertEqual(self.outcome([h1_response(b"ok"), 0.05, "close"]), 200)


class H2cStreams(unittest.TestCase):
    def call(self, answer, path="/health"):
        """The outcome of one `path` on a fresh H2c connection whose warm-up
        is answered whole, and of a second `/health` on it."""
        server = h2_server(lambda s, p: ok_frames(s, p) if p == "/worker" or s > 3 else answer(s))
        try:
            conn = hol_client.H2c(server.port)
            first = conn.call(path, 2.0)
            return first, conn.call("/health", 2.0)
        finally:
            server.close()

    def assertMalformed(self, outcome):
        self.assertTrue(hol_client.is_malformed(outcome), outcome)

    def test_a_whole_stream_is_its_status(self):
        self.assertEqual(self.call(lambda s: ok_frames(s, "/health")), (200, 200))

    def test_an_unreadable_status_is_malformed_and_the_reader_lives_on(self):
        # #133 review: an empty HEADERS raised IndexError and a non-numeric
        # :status ValueError in the reader thread, which then died, so every
        # later stream timed out and counted as lost.
        for block in (b"", b"\x08\x03abc", b"\x08\x03\xe0ab", b"\x01\x0390x", b"\x9f", b"\x20\x88"):
            with self.subTest(block=block):
                first, second = self.call(lambda s: [frame(1, 0x5, s, block)])
                self.assertMalformed(first)
                self.assertEqual(second, 200)
        self.assertEqual(self.call(lambda s: [frame(1, 0x5, s, b"\x08\x03204")]), (204, 200))
        self.assertEqual(self.call(lambda s: [frame(1, 0x5, s, b"\x48\x03204")]), (204, 200))

    def test_a_stream_cut_after_its_first_frame_is_malformed(self):
        # #133 review: HEADERS 200 and DATA "o" without END_STREAM, then the
        # connection closed, counted as closed (lost).
        cut = lambda s: [frame(1, 0x4, s, b"\x88"), frame(0, 0x0, s, b"o"), "close"]
        self.assertMalformed(self.call(cut)[0])
        self.assertMalformed(self.call(lambda s: [frame(1, 0x4, s, b"\x88"), "close"])[0])
        reset = lambda s: [frame(1, 0x4, s, b"\x88"), frame(3, 0, s, b"\x00\x00\x00\x02")]
        self.assertMalformed(self.call(reset)[0])

    def test_a_stream_cut_before_its_first_frame_is_not_malformed(self):
        self.assertEqual(self.call(lambda s: ["close"])[0], "closed")
        self.assertEqual(self.call(lambda s: [frame(3, 0, s, b"\x00\x00\x00\x02")]), ("reset", 200))

    def test_a_stalled_stream_is_malformed_once_it_began(self):
        server = h2_server(lambda s, p: ok_frames(s, p) if p == "/worker" else [frame(1, 0x4, s, b"\x88")])
        try:
            self.assertMalformed(hol_client.H2c(server.port).call("/health", 0.3))
        finally:
            server.close()

    def test_other_bodies_and_frames_are_malformed(self):
        for answer in (
            lambda s: [frame(1, 0x5, s, b"\x88")],  # 200 with no DATA
            lambda s: [frame(1, 0x4, s, b"\x88"), frame(0, 0x1, s, b"no")],
            lambda s: [frame(0, 0x1, s, b"ok")],  # DATA before HEADERS
            lambda s: [frame(1, 0x1, s, b"\x88")],  # no END_HEADERS: CONTINUATION
        ):
            with self.subTest(answer=answer):
                self.assertMalformed(self.call(answer)[0])

    def test_a_reader_error_fails_its_streams_as_malformed(self):
        server = h2_server(lambda s, p: ok_frames(s, p))
        try:
            conn = hol_client.H2c(server.port)
            conn.status = lambda block: 1 / 0
            self.assertMalformed(conn.call("/health", 2.0))
            self.assertMalformed(conn.call("/health", 2.0))
        finally:
            server.close()


class Runs(unittest.TestCase):
    """main() in control mode (no slow request, no FIFO), with the run's
    constants shortened."""

    def setUp(self):
        saved = {k: getattr(hol_client, k) for k in ("HOLD_AT_S", "CONTROL_S", "TAIL_S", "ANSWER_BOUND_S", "POOL")}
        hol_client.HOLD_AT_S, hol_client.CONTROL_S, hol_client.TAIL_S, hol_client.ANSWER_BOUND_S = 0.05, 0.3, 0.1, 1.0
        self.addCleanup(lambda: [setattr(hol_client, k, v) for k, v in saved.items()])

    def run_main(self, server, mode):
        argv = sys.argv
        sys.argv = ["hol_client.py", str(server.port), mode, "0", "unused"]
        try:
            return hol_client.main()
        finally:
            sys.argv = argv
            server.close()

    def test_whole_answers_exit_0(self):
        for mode in ("h1-new", "h1-pool", "h1-pool-fixed"):
            with self.subTest(mode=mode):
                self.assertEqual(self.run_main(h1_server(lambda p: [h1_response(OK[p])]), mode), 0)
        self.assertEqual(self.run_main(h2_server(ok_frames), "h2c-same"), 0)

    def test_malformed_answers_exit_1(self):
        broken = {
            "no length": lambda p: [h1_response(b"", [])] if p == "/health" else [h1_response(OK[p])],
            "stray byte after one read": lambda p: [padded_to(4096, OK[p]), 0.02, b"X"] if p == "/health" else [h1_response(OK[p])],
        }
        for name, answer in broken.items():
            for mode in ("h1-new", "h1-pool", "h1-pool-fixed"):
                with self.subTest(case=name, mode=mode):
                    self.assertEqual(self.run_main(h1_server(answer), mode), 1)
        for name, answer in {
            "empty HEADERS": lambda s, p: ok_frames(s, p) if p == "/worker" else [frame(1, 0x5, s, b"")],
            "cut after DATA": lambda s, p: ok_frames(s, p) if p == "/worker" else [frame(1, 0x4, s, b"\x88"), frame(0, 0, s, b"o"), "close"],
        }.items():
            with self.subTest(case=name, mode="h2c-same"):
                self.assertEqual(self.run_main(h2_server(answer), "h2c-same"), 1)

    def test_a_stray_byte_on_a_connection_left_idle_exits_1(self):
        # The last answer on a kept-open connection is checked at the end
        # of the run: its stray byte comes after the answer was read.
        # More connections than probes, so each probe takes one no probe
        # used before and none is read again after its `/health`.
        hol_client.POOL = 40
        answer = lambda p: [padded_to(4096, OK[p]), 0.02, b"X"] if p == "/health" else [h1_response(OK[p])]
        self.assertEqual(self.run_main(h1_server(answer), "h1-pool"), 1)
        self.assertEqual(self.run_main(h1_server(lambda p: [h1_response(OK[p])]), "h1-pool"), 0)


if __name__ == "__main__":
    unittest.main()
