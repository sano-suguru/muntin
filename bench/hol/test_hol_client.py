"""Tests of hol_client.py's response checks (Python standard library only),
against scripted servers on loopback: each response that is not whole
(hol_client.h1_read_response and hol_client.H2c say what that means) must
come out malformed, and a run that gets one must exit 1. scripts/check.sh
runs it.

    python3 -I bench/hol/test_hol_client.py
"""

import contextlib
import io
import os
import socket
import struct
import sys
import threading
import time
import unittest
import warnings

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
        for name, answer in {
            "plain": [h1_response(b"ok")],
            "Flare's fields": [h1_response(b"ok", [b"Content-Length: 2", b"Date: Fri, 16 Oct 2026 13:59:32 GMT",
                                                   b"Connection: close"])],
            "head and body apart": [h1_response(b"ok")[:-2], 0.02, b"ok"],
            "leading zeros": [h1_response(b"ok", [b"Content-Length: 0002"])],
            # The review: 4400 digits made int() raise in the probe thread.
            "4400 leading zeros": [h1_response(b"ok", [b"Content-Length: " + b"0" * 4400 + b"2"])],
            "a list of one length": [h1_response(b"ok", [b"Content-Length: 2, 2"])],
            "the same length twice": [h1_response(b"ok", [b"Content-Length: 2", b"content-length:2"])],
            "a tab and no reason phrase": [b"HTTP/1.1 200 \r\ncontent-length:\t2 \r\n\r\nok"],
            "an interim 100 first": [b"HTTP/1.1 100 Continue\r\n\r\n", h1_response(b"ok")],
        }.items():
            with self.subTest(case=name):
                self.assertEqual(self.outcome(answer), 200)

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
            # The review: field lines split on the first colon and stripped.
            [h1_response(b"ok", [b"X: a", b" Content-Length: 2"])],  # obs-fold
            [b"HTTP/1.1 200 OK\r\n Content-Length: 2\r\n\r\nok"],
            [b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX: y\nContent-Length: 3\r\n\r\nok"],  # bare LF
            [b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX: y\nTransfer-Encoding: chunked\r\n\r\nok"],
            [h1_response(b"ok", [b"Content-Length: 2", b"X: a\rb"])],  # bare CR
            [h1_response(b"ok", [b"Content-Length: 2", b": x"])],  # empty name
            [h1_response(b"ok", [b"Content-Length : 2"])],  # space before the colon
            [h1_response(b"ok", [b"Content-Length: 2", b"X: \x00"])],
            [h1_response(b"ok", [b"Content-Length: 2, 3"])],
            [h1_response(b"ok", [b"Content-Length: " + b"9" * 20])],
            [b"HTTP/1.1 101 Switching Protocols\r\n\r\n", h1_response(b"ok")],
            [b"HTTP/1.1 100 Continue\r\n\r\n", "close"],
            [b"HTTP/1.1 204 No Content\r\nContent-Length: 2\r\n\r\nok"],
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
            conn.sock.close()
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
            conn.sock.close()
        finally:
            server.close()

    def test_a_close_response_must_be_followed_by_eof(self):
        self.assertMalformed(self.outcome([h1_response(b"ok"), 0.05, b"X", "close"]))
        self.assertEqual(self.outcome([h1_response(b"ok"), 0.05, "close"]), 200)
        # On a kept-open connection, a response that says `Connection: close`
        # (the review: such a connection went back to the pool).
        closing = h1_response(b"ok", [b"Content-Length: 2", b"Connection: close"])
        for answer, outcome in (([closing, 0.05, b"X", "close"], None), ([closing, "close"], 200)):
            server = h1_server(lambda p: answer)
            try:
                conn = hol_client.H1(server.port, ask_worker=False)
                if outcome is None:
                    with self.assertRaises(hol_client.Malformed):
                        conn.call("/health")
                else:
                    self.assertEqual(conn.call("/health")[0], outcome)
                conn.sock.close()
            finally:
                server.close()


def headers_then_ok(block, flags=0x4):
    """A stream's HEADERS with `block`, then DATA `ok` ending it."""
    return lambda s: [frame(1, flags, s, block), frame(0, 0x1, s, b"ok")]


class H2cStreams(unittest.TestCase):
    def call(self, answer, path="/health", timeout=2.0):
        """(outcome of one `path`, outcome of a second `/health`, the
        connection's errors) on a fresh H2c connection whose warm-up and
        later streams are answered whole; `answer(stream)` answers the
        first."""
        server = h2_server(lambda s, p: ok_frames(s, p) if p == "/worker" or s > 3 else answer(s))
        try:
            conn = hol_client.H2c(server.port)
            first = conn.call(path, timeout)
            second = conn.call("/health", timeout)
            conn.sock.close()
            return first, second, conn.errors
        finally:
            server.close()

    def assertMalformed(self, outcome):
        self.assertTrue(hol_client.is_malformed(outcome), outcome)

    def test_whole_streams_are_their_status(self):
        pad = lambda payload, n: bytes([n]) + payload + bytes(n)
        for name, answer in {
            "plain": lambda s: ok_frames(s, "/health"),
            "a table size update first": headers_then_ok(b"\x20\x88"),
            "literal :status, indexed into the table and reused": lambda s: [
                frame(1, 0x4, s, b"\x48\x03200"), frame(0, 0x1, s, b"ok")],
            "content-length": headers_then_ok(b"\x88\x0f\x0d\x012"),
            "padded DATA": lambda s: [frame(1, 0x4, s, b"\x88"), frame(0, 0x9, s, pad(b"ok", 3))],
            "padded HEADERS with priority": lambda s: [
                frame(1, 0x2C, s, pad(b"\x00\x00\x00\x00\x10" + b"\x88", 2)), frame(0, 0x1, s, b"ok")],
            "CONTINUATION": lambda s: [frame(1, 0x0, s, b"\x88"), frame(9, 0x4, s, b"\x0f\x0d\x012"),
                                       frame(0, 0x1, s, b"ok")],
            "an interim 103 first": lambda s: [frame(1, 0x4, s, b"\x08\x03103"), frame(1, 0x4, s, b"\x88"),
                                              frame(0, 0x1, s, b"ok")],
            "trailers": lambda s: [frame(1, 0x4, s, b"\x88"), frame(0, 0x0, s, b"ok"),
                                   frame(1, 0x5, s, b"\x00\x01x\x01y")],
            "DATA split, and an empty last one": lambda s: [frame(1, 0x4, s, b"\x88"), frame(0, 0, s, b"o"),
                                                            frame(0, 0, s, b"k"), frame(0, 0x1, s, b"")],
            "PING, WINDOW_UPDATE and an unknown frame between": lambda s: [
                frame(1, 0x4, s, b"\x88"), frame(6, 0, 0, bytes(8)), frame(8, 0, s, b"\x00\x00\x00\x01"),
                frame(0xEE, 0, s, b"x"), frame(0, 0x1, s, b"ok")],
            "a graceful GOAWAY mid-stream": lambda s: [
                frame(1, 0x4, s, b"\x88"), frame(7, 0, 0, b"\x7f\xff\xff\xff\x00\x00\x00\x00"),
                frame(0, 0x1, s, b"ok")],
        }.items():
            with self.subTest(case=name):
                first, second, errors = self.call(answer)
                self.assertEqual(first, 200)
                self.assertEqual(errors, [])
                if name != "a graceful GOAWAY mid-stream":
                    self.assertEqual(second, 200)
        self.assertEqual(self.call(lambda s: [frame(1, 0x5, s, b"\x08\x03204")])[:2], (204, 200))

    def test_an_unreadable_head_is_malformed_and_the_reader_lives_on(self):
        # #133 review: an empty HEADERS raised IndexError and a non-numeric
        # :status ValueError in the reader thread, which then died, so every
        # later stream timed out and counted as lost.
        for block in (
            b"",  # no :status
            b"\x08\x03abc",
            b"\x08\x83abc",  # Huffman-coded, which this client does not decode
            b"\x08\x04200 ",
            b"\x01\x0390x",  # :authority
            b"\x9f",  # content-type, no :status
            b"\x88\x88",  # two :status
            b"\x0f\x0d\x012\x88",  # a pseudo-header after a field
            b"\x88\x00\x01X\x01y",  # uppercase name
            b"\x88\x00\x0aconnection\x05close",
            b"\x88\x0f\x0d\x015",  # content-length 5 with DATA "ok"
            b"\x08\x03101",
        ):
            with self.subTest(block=block):
                first, second, errors = self.call(headers_then_ok(block))
                self.assertMalformed(first)
                self.assertEqual((second, errors), (200, []))

    def test_an_hpack_error_fails_the_connection(self):
        for block in (b"\x88\xff\xff\xff\xff\xff", b"\x88\x40\x05ab", b"\xbe", b"\x88\x20"):
            with self.subTest(block=block):
                first, second, errors = self.call(headers_then_ok(block))
                self.assertMalformed(first)
                self.assertMalformed(second)
                self.assertTrue(errors)

    def test_a_stream_cut_after_its_response_began_is_malformed(self):
        # #133 review: HEADERS 200 and DATA "o" without END_STREAM, then the
        # connection closed, counted as closed (lost).
        for name, answer in {
            "closed after DATA": lambda s: [frame(1, 0x4, s, b"\x88"), frame(0, 0x0, s, b"o"), "close"],
            "closed after HEADERS": lambda s: [frame(1, 0x4, s, b"\x88"), "close"],
            "closed inside a frame": lambda s: [frame(1, 0x4, s, b"\x88")[:9], "close"],
            "reset after HEADERS": lambda s: [frame(1, 0x4, s, b"\x88"), frame(3, 0, s, b"\x00\x00\x00\x02")],
            "GOAWAY not covering it after HEADERS": lambda s: [
                frame(1, 0x4, s, b"\x88"), frame(7, 0, 0, b"\x00\x00\x00\x01\x00\x00\x00\x00")],
            "an interim 103, then closed": lambda s: [frame(1, 0x4, s, b"\x08\x03103"), "close"],
        }.items():
            with self.subTest(case=name):
                self.assertMalformed(self.call(answer)[0])
        # Stalled: inside a frame (the review's partial frame), or between frames.
        for answer in (lambda s: [frame(1, 0x4, s, b"\x88\x88")[:10]], lambda s: [frame(1, 0x4, s, b"\x88")]):
            self.assertMalformed(self.call(answer, timeout=0.3)[0])

    def test_a_stream_cut_before_its_response_began_is_not_malformed(self):
        self.assertEqual(self.call(lambda s: ["close"])[0], "closed")
        self.assertEqual(self.call(lambda s: [frame(3, 0, s, b"\x00\x00\x00\x02")])[:2], ("reset", 200))
        self.assertEqual(self.call(lambda s: [], timeout=0.3)[0], "timeout")
        goaway = lambda s: [frame(7, 0, 0, b"\x00\x00\x00\x01\x00\x00\x00\x00")]
        self.assertEqual(self.call(goaway)[:2], ("goaway", "goaway"))

    def test_other_bodies_and_frames_are_malformed(self):
        for name, answer in {
            "200 with no DATA": lambda s: [frame(1, 0x5, s, b"\x88")],
            "another body": lambda s: [frame(1, 0x4, s, b"\x88"), frame(0, 0x1, s, b"no")],
            "DATA before HEADERS": lambda s: [frame(0, 0x1, s, b"ok")],
            "DATA on a 204": lambda s: [frame(1, 0x4, s, b"\x89"), frame(0, 0x1, s, b"ok")],
            "a second head, not trailers": lambda s: [frame(1, 0x4, s, b"\x88"), frame(1, 0x4, s, b"\x88"),
                                                      frame(0, 0x1, s, b"ok")],
            "trailers with a pseudo-header": lambda s: [frame(1, 0x4, s, b"\x88"), frame(0, 0, s, b"ok"),
                                                        frame(1, 0x5, s, b"\x88")],
            "an interim 103 ending the stream": lambda s: [frame(1, 0x5, s, b"\x08\x03103")],
        }.items():
            with self.subTest(case=name):
                first, second, errors = self.call(answer)
                self.assertMalformed(first)
                self.assertEqual(errors, [])

    def test_a_connection_error_fails_every_stream(self):
        # The review: a response on a stream the client did not open was
        # dropped, and the stream it answers timed out as lost.
        for name, answer in {
            "the answer on a stream never opened": lambda s: [frame(1, 0x4, s + 2, b"\x88"), frame(0, 1, s + 2, b"ok")],
            "the answer on an even stream": lambda s: [frame(1, 0x4, s + 1, b"\x88"), frame(0, 1, s + 1, b"ok")],
            "HEADERS on stream 0": lambda s: [frame(1, 0x4, 0, b"\x88")],
            "DATA after END_STREAM": lambda s: ok_frames(s, "/health") + [frame(0, 0x1, s, b"ok")],
            "HEADERS after END_STREAM": lambda s: ok_frames(s, "/health") + [frame(1, 0x5, s, b"\x88")],
            "a frame between HEADERS and CONTINUATION": lambda s: [frame(1, 0x0, s, b"\x88"), frame(0, 1, s, b"ok")],
            "CONTINUATION alone": lambda s: [frame(9, 0x4, s, b"\x88")],
            "PUSH_PROMISE": lambda s: [frame(5, 0x4, s, b"\x00\x00\x00\x02\x82")],
            "padding longer than its frame": lambda s: [frame(1, 0x4, s, b"\x88"), frame(0, 0x9, s, b"\x05ok")],
            "a frame of 16385 bytes": lambda s: [frame(1, 0x4, s, b"\x88"), frame(0, 0x1, s, bytes(16385))],
        }.items():
            with self.subTest(case=name):
                first, second, errors = self.call(answer, timeout=0.5)
                if name.endswith("after END_STREAM"):
                    self.assertEqual(first, 200)
                else:
                    self.assertMalformed(first)
                self.assertMalformed(second)
                self.assertTrue(errors)

    def test_a_reader_error_fails_its_streams_as_malformed(self):
        server = h2_server(lambda s, p: ok_frames(s, p))
        try:
            conn = hol_client.H2c(server.port)
            conn.hpack.decode = lambda block: 1 / 0
            self.assertMalformed(conn.call("/health", 2.0))
            self.assertMalformed(conn.call("/health", 2.0))
            self.assertTrue(conn.errors)
            conn.sock.close()
        finally:
            server.close()


class Runs(unittest.TestCase):
    """main() in control mode (no slow request, no FIFO), with the run's
    constants shortened."""

    def setUp(self):
        # main() leaves its connections to the process's exit.
        warnings.simplefilter("ignore", ResourceWarning)
        saved = {k: getattr(hol_client, k) for k in ("HOLD_AT_S", "CONTROL_S", "TAIL_S", "ANSWER_BOUND_S", "POOL")}
        hol_client.HOLD_AT_S, hol_client.CONTROL_S, hol_client.TAIL_S, hol_client.ANSWER_BOUND_S = 0.05, 0.3, 0.1, 1.0
        self.addCleanup(lambda: [setattr(hol_client, k, v) for k, v in saved.items()])

    def run_main(self, server, mode):
        argv = sys.argv
        sys.argv = ["hol_client.py", str(server.port), mode, "0", "unused"]
        try:
            with contextlib.redirect_stdout(io.StringIO()):
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
            "a response on a stream never opened": lambda s, p: (
                ok_frames(s, p) if p == "/worker" else ok_frames(s + 2, p)),
            "DATA after END_STREAM": lambda s, p: (
                ok_frames(s, p) if p == "/worker" else ok_frames(s, p) + [frame(0, 1, s, b"ok")]),
            "empty HEADERS": lambda s, p: ok_frames(s, p) if p == "/worker" else [frame(1, 0x5, s, b"")],
            "cut after DATA": lambda s, p: ok_frames(s, p) if p == "/worker" else [frame(1, 0x4, s, b"\x88"), frame(0, 0, s, b"o"), "close"],
        }.items():
            with self.subTest(case=name, mode="h2c-same"):
                self.assertEqual(self.run_main(h2_server(answer), "h2c-same"), 1)

    def test_a_client_error_exits_1(self):
        # The review: an exception the probe did not catch ended its thread,
        # and the probe was never counted.
        def broken(*args):
            raise RuntimeError("client bug")

        original = hol_client.h1_new_call
        hol_client.h1_new_call = broken
        try:
            self.assertEqual(self.run_main(h1_server(lambda p: [h1_response(OK[p])]), "h1-new"), 1)
        finally:
            hol_client.h1_new_call = original

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
