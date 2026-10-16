"""The head-of-line blocking measurement's client (Python standard library
only). Not part of Muntin and not run by CI; scripts/bench_hol.sh runs it.

    python3 hol_client.py PORT MODE SLOW_MS SIGNAL

One run against a fresh server on 127.0.0.1:PORT (bench/hol/hol_muntin.mojo
or hol_flare.mojo) started with `HOL_SIGNAL=SIGNAL`, a FIFO this client
reads. It opens the connections MODE needs and asks `/worker` on each, so
every one is accepted, idle and known to belong to one worker when the hold
starts. At `HOLD_AT_S` it asks `/worker`, then `GET /slow/SLOW_MS`, on a
connection of its own (for the h2c modes, on the h2c connection named
below). That handler writes `s` to SIGNAL when it starts and `e` when it
returns; the hold is the time between the two, as this client reads them.
From the start to `HOLD_AT_S + SLOW_MS + TAIL_S` it sends `GET /health`
every `PERIOD_S`, each from its own thread, and records for each probe when
it started, when it was sent (when it began writing its request to a
connected socket: after a pool probe got its connection, after an `h1-new`
probe connected), whether that write completed (the whole request handed to
the kernel) or failed, and whether and when it was answered. A probe whose
write completed with no answer `ANSWER_BOUND_S` after the hold ended is
lost, as is one whose connection was closed or reset before any of its
answer arrived; a probe whose write failed is not lost but write-failed; a
probe never sent (no pool connection came free in time, the connection
could not be opened, the h2c connection was already gone) is neither, but
not sent. A response that began to arrive but is not whole
(`h1_read_response` and `H2c` say what that means: framing, and the body
each route answers) is malformed, not lost, whichever request it answers;
an answer that comes after its probe gave up is still read and checked
until the end of the run (`H2c.settle`, `Late`), and the probe stays lost.
Any malformed response makes the run no measurement, and the client exits 1
after printing its line.

With SLOW_MS 0 (a control) no slow request is sent, and the window is the
`CONTROL_S` from `HOLD_AT_S`: what the same probes get with no handler held.

MODE is where the probes go:
- `h1-new`: each probe on a new HTTP/1.1 connection (`Connection: close`).
- `h1-pool`: HTTP/1.1 keep-alive connections, `POOL` opened before the hold;
  a probe takes an idle one, opens a new one when none is idle (no upper
  bound), and puts it back once answered.
- `h1-pool-fixed`: as `h1-pool`, but never more than `POOL` connections: a
  probe with none idle waits for one (up to the answer bound, then not
  sent).
- `h2c-same`: prior-knowledge h2c; the slow request is a stream of the
  connection every probe is a later stream of.
- `h2c-other`: as `h2c-same`, with the slow request on a second h2c
  connection.
- `spread`: no slow request; how a server spreads kept-open connections
  over its workers (`spread` below).
- `capacity-K`: K slow requests held at once, then one `/health` on a new
  connection (`capacity` below): how many blocking handlers stop a server.

It prints one line: `MODE n=<probes sent during the hold> during=<answered
before the hold ended> after=<answered after it> lost=<written, not
answered 200: no answer, or a whole one with another status, which
`lost_as` names> write_failed=<write failed> p50_ms=<median latency of the
answered, from sending> max_ms=<largest> slow=<the slow request's outcome>
hold_ms=<the hold as signalled> started=<probes started during the hold>
sent_after=<of those, sent after it ended>/<lost>/<write failed>
not_sent=<probes of the run never sent>` (for a control, "the hold" is its
window), then, where the probes' connections are known (every mode but
`h1-new`, and only for connections opened before the hold),
`slow_worker=<sent>/<lost>/<write failed>` and `other_workers=` the same:
the probes on connections of the slow request's worker and of the others;
for the pool modes, `lost_idle_ms=<least>..<most>`: how long each lost
probe's connection had been idle (since its previous answer) when the probe
was sent; `lost_as`, `write_failed_as` and `not_sent_as`: why; and, if any,
`malformed=<malformed responses of the run, the slow request's included,
kept-open connections with bytes left after their last response, and h2c
connection errors>` and `malformed_as`: what was wrong with them; and
`client_errors=` and `client_errors_as=`: requests this client failed on
itself (an exception), which also make the run exit 1. Latency figures
cover answered probes only: read them with `lost`.
"""

import os
import re
import socket
import struct
import sys
import threading
import time

HOLD_AT_S = 0.3
PERIOD_S = 0.05
TAIL_S = 0.7
ANSWER_BOUND_S = 3.0
CONTROL_S = 1.0
POOL = 8
SPREAD = 16


def h1_request(path, close):
    extra = "Connection: close\r\n" if close else ""
    return f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n{extra}\r\n".encode()


class Malformed(Exception):
    """A response that began to arrive but is not whole: see
    `h1_read_response` and `H2c`."""


def is_malformed(outcome):
    return str(outcome).startswith("malformed: ")


def expected(path, body):
    """Whether `body` is what the hol servers answer `GET path` with: `ok`,
    `slow`, or a worker number."""
    if path == "/health":
        return body == b"ok"
    if path.startswith("/slow/"):
        return body == b"slow"
    if path == "/worker":
        return body.isdigit()
    return False


TOKEN = re.compile(rb"[!#$%&'*+\-.^_`|~0-9A-Za-z]+")


def h1_read_response(sock, path):
    """(status, fields, body) of the response to `GET path`, fields mapping
    each lowercased name to its values; interim 1xx responses before it are
    read and dropped. Raises ConnectionError("closed") on EOF before the
    response's first byte, and Malformed once any of it has arrived unless
    it is whole (RFC 9112):
    - an `HTTP/1.1 NNN reason` status line (not 101: nothing was upgraded);
    - field lines `name: value` with a token name, no whitespace before the
      colon, no obs-fold, no NUL, and no CR or LF but the CRLF ending each;
    - no `Transfer-Encoding` (this client reads no chunked body);
    - for 204 and 304, no body (and no `Content-Length` on a 204); for any
      other status, `Content-Length` values (one field, or several, or a
      list) that are all the same number, and exactly that many body bytes;
    - no bytes after the body (no request is pipelined);
    - for a 200, the body `expected` names.
    An error, EOF or timeout after the first byte is Malformed too, as is a
    response this client cannot parse. Bytes after the body count whether
    they were read with it or are already waiting on `sock`; any that arrive
    later are found by the next read on the connection, by `expect_eof`
    after a response that closes it, or by the run's final `pending` check
    of a connection it keeps open."""
    data = b""
    began = False
    try:
        while True:  # one pass per response head, interim ones first
            while b"\r\n\r\n" not in data:
                chunk = sock.recv(4096)
                if not chunk:
                    raise ConnectionError("closed")
                data += chunk
                began = True
            head, _, data = data.partition(b"\r\n\r\n")
            status, fields = h1_head(head)
            if not 100 <= status < 200:
                break
        if b"transfer-encoding" in fields:
            raise Malformed("Transfer-Encoding, which this client does not read")
        if status in (204, 304):
            if status == 204 and b"content-length" in fields:
                raise Malformed("Content-Length on a 204")
            length = 0
        else:
            lengths = {v.strip(b" \t") for line in fields.get(b"content-length", []) for v in line.split(b",")}
            if not lengths:
                raise Malformed("no Content-Length")
            if len(lengths) != 1 or not all(v.isdigit() for v in lengths):
                raise Malformed(f"Content-Length {sorted(lengths)[:3]}")
            digits = lengths.pop().lstrip(b"0") or b"0"
            if len(digits) > 12:
                raise Malformed(f"Content-Length of {len(digits)} digits")
            length = int(digits)
        body = data
        while len(body) < length:
            chunk = sock.recv(4096)
            if not chunk:
                raise Malformed(f"closed after {len(body)} of {length} body bytes")
            body += chunk
    except OSError as e:  # ConnectionError and socket.timeout included
        if began:
            raise Malformed(f"{failure(e)} in the middle of a response") from e
        raise
    except (ValueError, IndexError) as e:  # what parsing it raised
        raise Malformed(f"unparsable: {type(e).__name__}: {e}") from e
    extra = len(body) - length + pending(sock)
    if extra:
        raise Malformed(f"{extra} bytes after the body")
    if status == 200 and not expected(path, body):
        raise Malformed(f"body {body[:40]!r}")
    return status, fields, body


def h1_head(head):
    """(status, fields) of a response head without its final CRLF CRLF, or
    Malformed."""
    if b"\r" in head.replace(b"\r\n", b"") or b"\n" in head.replace(b"\r\n", b""):
        raise Malformed("a bare CR or LF in the head")
    lines = head.split(b"\r\n")
    status = re.fullmatch(rb"HTTP/1\.1 ([1-5][0-9][0-9]) [\t \x21-\x7e\x80-\xff]*", lines[0])
    if status is None:
        raise Malformed(f"status line {lines[0][:40]!r}")
    if status.group(1) == b"101":
        raise Malformed("101 Switching Protocols")
    fields = {}
    for line in lines[1:]:
        if line[:1] in (b" ", b"\t"):
            raise Malformed(f"obs-fold or whitespace before a field line {line[:40]!r}")
        name, sep, value = line.partition(b":")
        if not sep or not TOKEN.fullmatch(name):
            raise Malformed(f"field line {line[:40]!r}")
        if b"\x00" in value:
            raise Malformed(f"NUL in field {name!r}")
        fields.setdefault(name.lower(), []).append(value.strip(b" \t"))
    return int(status.group(1)), fields


def closes(fields):
    """Whether a response's fields close its connection (`Connection: close`)."""
    return any(b"close" in [t.strip(b" \t").lower() for t in v.split(b",")] for v in fields.get(b"connection", []))


def expect_eof(sock):
    """Reads `sock` to EOF after a whole response that closes its
    connection (or answers `Connection: close`); Malformed if anything but
    EOF comes, or if the connection stays open until `sock`'s timeout."""
    extra = 0
    try:
        while chunk := sock.recv(4096):
            extra += len(chunk)
    except OSError as e:
        raise Malformed(f"{failure(e)} instead of EOF after the response") from e
    if extra:
        raise Malformed(f"{extra} bytes after the body")


def pending(sock):
    """How many bytes are waiting unread on `sock` now, without waiting for
    any (0 at EOF or on an error)."""
    timeout = sock.gettimeout()
    sock.settimeout(0)
    try:
        return len(sock.recv(4096, socket.MSG_PEEK))
    except OSError:  # BlockingIOError (none waiting) included
        return 0
    finally:
        sock.settimeout(timeout)


def write(sock, data, note):
    """Writes a probe's request: note["sent"] when the write begins,
    note["written"] once all of it is handed to the kernel, or
    note["write_failed"] (why) and the error raised again."""
    note["sent"] = time.monotonic()
    try:
        sock.sendall(data)
    except OSError as e:
        note["write_failed"] = failure(e)
        raise
    note["written"] = time.monotonic()


def h1_connect(port):
    sock = socket.create_connection(("127.0.0.1", port))
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return sock


def failure(e):
    if isinstance(e, Malformed):
        return f"malformed: {e}"
    if isinstance(e, socket.timeout):
        return "timeout"
    return str(e) or type(e).__name__


class H1:
    """One HTTP/1.1 keep-alive connection, with the worker that serves it
    and when it last answered."""

    def __init__(self, port, ask_worker=True):
        self.sock = h1_connect(port)
        self.sock.settimeout(2.0)
        # A connection opened during the hold is not asked: its worker could
        # be the held one, and asking would wait for the hold.
        self.worker = self.call("/worker")[2] if ask_worker else None
        self.last = time.monotonic()

    def call(self, path):
        self.sock.sendall(h1_request(path, False))
        status, fields, body = h1_read_response(self.sock, path)
        if closes(fields):
            expect_eof(self.sock)
        return status, fields, body


# RFC 7541 Appendix A: the static table, from index 1.
STATIC = [None] + [(n.encode(), v.encode()) for n, v in (
    (":authority", ""), (":method", "GET"), (":method", "POST"), (":path", "/"), (":path", "/index.html"),
    (":scheme", "http"), (":scheme", "https"), (":status", "200"), (":status", "204"), (":status", "206"),
    (":status", "304"), (":status", "400"), (":status", "404"), (":status", "500"), ("accept-charset", ""),
    ("accept-encoding", "gzip, deflate"), ("accept-language", ""), ("accept-ranges", ""), ("accept", ""),
    ("access-control-allow-origin", ""), ("age", ""), ("allow", ""), ("authorization", ""),
    ("cache-control", ""), ("content-disposition", ""), ("content-encoding", ""), ("content-language", ""),
    ("content-length", ""), ("content-location", ""), ("content-range", ""), ("content-type", ""),
    ("cookie", ""), ("date", ""), ("etag", ""), ("expect", ""), ("expires", ""), ("from", ""), ("host", ""),
    ("if-match", ""), ("if-modified-since", ""), ("if-none-match", ""), ("if-range", ""),
    ("if-unmodified-since", ""), ("last-modified", ""), ("link", ""), ("location", ""), ("max-forwards", ""),
    ("proxy-authenticate", ""), ("proxy-authorization", ""), ("range", ""), ("referer", ""), ("refresh", ""),
    ("retry-after", ""), ("server", ""), ("set-cookie", ""), ("strict-transport-security", ""),
    ("transfer-encoding", ""), ("user-agent", ""), ("vary", ""), ("via", ""), ("www-authenticate", ""),
)]
# RFC 9113 section 8.2.2: fields a response must not carry over HTTP/2.
CONNECTION_SPECIFIC = {b"connection", b"keep-alive", b"proxy-connection", b"transfer-encoding", b"upgrade"}


class Hpack:
    """An HPACK decoder (RFC 7541) for a connection's response header
    blocks, with the static and dynamic tables. This client does not decode
    Huffman: a Huffman-coded string is None, and once one enters the dynamic
    table its size is unknown, so a later reference to that table fails.
    `decode` raises (Malformed, or what indexing raised) on a block it
    cannot decode, a connection error (RFC 9113 section 4.3)."""

    def __init__(self):
        self.table = []  # newest first: (name, value)
        self.size = 0
        self.max_size = 4096  # SETTINGS_HEADER_TABLE_SIZE: this client sends the default
        self.unknown = False

    @staticmethod
    def integer(block, i, prefix):
        mask = (1 << prefix) - 1
        value, i = block[i] & mask, i + 1
        if value < mask:
            return value, i
        shift = 0
        while True:
            byte, i = block[i], i + 1
            value += (byte & 0x7F) << shift
            if not byte & 0x80:
                return value, i
            shift += 7
            if shift > 28:
                raise Malformed("an HPACK integer too long")

    def string(self, block, i):
        huffman = block[i] & 0x80
        n, i = self.integer(block, i, 7)
        if i + n > len(block):
            raise Malformed("an HPACK string past the block")
        return (None if huffman else block[i : i + n]), i + n

    def entry(self, index):
        if 1 <= index <= 61:
            return STATIC[index]
        if index == 0 or self.unknown or index - 62 >= len(self.table):
            raise Malformed(f"HPACK index {index} not in the table this client holds")
        return self.table[index - 62]

    def evict(self):
        while self.size > self.max_size:
            name, value = self.table.pop()
            self.size -= len(name) + len(value) + 32

    def decode(self, block):
        try:
            return self.fields(block)
        except IndexError as e:
            raise Malformed("an HPACK block cut short") from e

    def fields(self, block):
        fields, i = [], 0
        while i < len(block):
            byte = block[i]
            if byte & 0x80:  # indexed
                index, i = self.integer(block, i, 7)
                fields.append(self.entry(index))
                continue
            if byte & 0xE0 == 0x20:  # dynamic table size update
                if fields:
                    raise Malformed("an HPACK table size update after a field")
                size, i = self.integer(block, i, 5)
                if size > 4096:
                    raise Malformed(f"an HPACK table size of {size}")
                self.max_size = size
                if not self.unknown:
                    self.evict()
                continue
            indexing = byte & 0xC0 == 0x40
            index, i = self.integer(block, i, 6 if indexing else 4)
            if index:
                name = self.entry(index)[0]
            else:
                name, i = self.string(block, i)
            value, i = self.string(block, i)
            fields.append((name, value))
            if indexing:
                if name is None or value is None or self.unknown:
                    self.unknown = True
                else:
                    self.table.insert(0, (name, value))
                    self.size += len(name) + len(value) + 32
                    self.evict()
        return fields


def h2_field(name, value):
    """Malformed unless the field is one a response may carry (RFC 9113
    section 8.2): its name a lowercase token after a pseudo-header's colon,
    its value without NUL, CR or LF and without SP or HTAB at either end,
    and not a connection-specific field. A Huffman-coded name or value
    (None) is Malformed too: this client does not decode it, so it cannot
    check it."""
    if name is None or value is None:
        which = "name" if name is None else repr(name[:20])
        raise Malformed(f"a Huffman-coded field {which}, which this client does not decode")
    if not re.fullmatch(rb":?[!#$%&'*+\-.^_`|~0-9a-z]+", name):
        raise Malformed(f"field name {name[:20]!r}")
    if re.search(rb"[\0\r\n]|^[ \t]|[ \t]$", value):
        raise Malformed(f"field {name[:20]!r} with the value {value[:20]!r}")
    if name in CONNECTION_SPECIFIC:
        raise Malformed(f"connection-specific field {name!r}")


def h2_response_head(fields):
    """(status, content-length or None) of a response header block's fields
    (RFC 9113 section 8.3.2), or Malformed: each field one `h2_field`
    accepts; one `:status` of three digits and no other pseudo-header,
    before every other field; `content-length` values all the same number."""
    status, lengths, regular = None, set(), False
    for name, value in fields:
        h2_field(name, value)
        if name.startswith(b":"):
            if regular or name != b":status" or status is not None:
                raise Malformed(f"pseudo-header {name[:20]!r}")
            if not re.fullmatch(rb"[1-5][0-9][0-9]", value):
                raise Malformed(f":status {value!r}")
            status = int(value)
            continue
        regular = True
        if name == b"content-length":
            lengths |= {v.strip(b" \t") for v in value.split(b",")}
    if status is None:
        raise Malformed("no :status")
    if not lengths:
        return status, None
    if len(lengths) != 1 or not all(v.isdigit() and len(v.lstrip(b"0")) <= 12 for v in lengths):
        raise Malformed(f"content-length {sorted(lengths)[:3]}")
    return status, int(lengths.pop())


class Stream:
    """One request's stream: `event` is set once `outcome` holds the status,
    or why there is none."""

    def __init__(self, path):
        self.path = path
        self.event = threading.Event()
        self.outcome = None
        self.status = None  # the final status, once its HEADERS arrived
        self.length = None  # its content-length, if it gave one
        self.body = b""
        self.begun = False  # a HEADERS, CONTINUATION or DATA frame of it began to arrive


class H2c:
    """A minimal prior-knowledge h2c client (RFC 9113): GET only, server push
    off, responses small enough for the default windows. One reader thread
    reads every frame. A stream's outcome is malformed if:
    - its response head is (`h2_response_head`), or an interim (1xx) one
      ends the stream or is 101;
    - DATA comes before its final HEADERS, a later header block is not
      trailers (END_STREAM, no pseudo-header, each field one `h2_field`
      accepts), or a 204 or 304 has DATA;
    - its DATA differs from its `content-length`, or a 200's body is not the
      one `expected` names;
    - it ends (reset, closed, GOAWAY, timeout) once a frame of it began to
      arrive.
    A connection error (RFC 9113 section 5.4.1: a frame on a stream never
    opened or already ended, an HPACK error, a frame larger than 16384
    bytes, CONTINUATION out of place, PUSH_PROMISE, bad padding, the
    connection ending inside a frame) and an error of the reader itself are
    malformed too: every open and later stream gets it, and `errors` keeps
    it for the end of the run. A stream's outcome is fixed when `call`
    returns it; the checks go on after a timeout, and what they find then
    is kept in `late`. `settle` ends the connection at the end of the run:
    a frame still not whole then is a connection error, since no stream it
    may belong to can be told apart from a timeout."""

    def __init__(self, port):
        self.port = port
        self.sock = h1_connect(port)
        self.lock = threading.Lock()
        self.next_id = 1
        self.waiting = {}  # stream id -> Stream
        self.ended = {}  # stream id -> whether frames may still come for it
        self.dead = None
        self.errors = []
        self.late = []  # malformed verdicts on streams `call` had already given up on
        self.closing = False  # `settle` shut the connection
        self.inside = 0  # bytes of the frame being read that have arrived, while the reader reads
        self.hpack = Hpack()
        no_push = struct.pack(">HI", 2, 0)  # SETTINGS_ENABLE_PUSH = 0
        self.sock.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + self.frame(4, 0, 0, no_push))
        self.reader = threading.Thread(target=self.read_loop, daemon=True)
        self.reader.start()
        stream = self.get("/worker")
        if not stream.event.wait(2.0) or stream.outcome != 200:
            raise ConnectionError(f"h2c warm-up failed: {stream.outcome}")
        self.worker = stream.body

    @staticmethod
    def frame(kind, flags, stream, payload):
        return struct.pack(">I", len(payload))[1:] + bytes([kind, flags]) + struct.pack(">I", stream) + payload

    def get(self, path, note=None):
        """Sends a GET; returns its Stream. Records the write in note as
        `write` does."""
        authority = f"127.0.0.1:{self.port}".encode()
        block = b"\x82\x86\x04" + bytes([len(path)]) + path.encode() + b"\x01" + bytes([len(authority)]) + authority
        stream = Stream(path)
        with self.lock:
            if self.dead is not None:
                stream.outcome = self.dead
                stream.event.set()
                return stream
            sid = self.next_id
            self.next_id += 2
            try:
                write(self.sock, self.frame(1, 0x5, sid, block), {} if note is None else note)
            except OSError as e:
                self.ended[sid] = True  # part of it may have gone
                stream.outcome = failure(e)
                stream.event.set()
                return stream
            self.waiting[sid] = stream
        return stream

    def recv_exact(self, n):
        """The next n bytes of the frame being read, counted in `inside`.
        The connection ending (closed or reset) once a byte of that frame
        arrived cuts the frame short: Malformed, a connection error, where
        between frames it is a close."""
        data = b""
        while len(data) < n:
            try:
                chunk = self.sock.recv(n - len(data))
            except OSError as e:
                if self.inside:
                    raise Malformed(f"the connection ended {self.inside} bytes into a frame: {failure(e)}") from e
                raise
            if not chunk:
                if self.inside and self.closing:
                    raise Malformed(f"a frame left {self.inside} bytes in at the end of the run")
                if self.inside:
                    raise Malformed(f"the connection closed {self.inside} bytes into a frame")
                raise ConnectionError("closed")
            data += chunk
            self.inside += len(chunk)
        return data

    @staticmethod
    def unpad(payload, flags):
        if not flags & 0x8:  # PADDED
            return payload
        if not payload or payload[0] >= len(payload):
            raise Malformed("padding longer than its frame")
        return payload[1 : len(payload) - payload[0]]

    def read_loop(self):
        block = None  # [stream id, END_STREAM, fragments] until END_HEADERS
        try:
            while True:
                self.inside = 0
                head = self.recv_exact(9)
                length = struct.unpack(">I", b"\x00" + head[:3])[0]
                kind, flags = head[3], head[4]
                sid = struct.unpack(">I", head[5:9])[0] & 0x7FFFFFFF
                if length > 16384:  # SETTINGS_MAX_FRAME_SIZE: the default
                    raise Malformed(f"a frame of {length} bytes")
                if kind in (0, 1, 9):
                    with self.lock:
                        if sid in self.waiting:
                            self.waiting[sid].begun = True
                payload = self.recv_exact(length)
                if block is not None:
                    if kind != 9 or sid != block[0]:
                        raise Malformed("a frame between HEADERS and its CONTINUATION")
                    block[2] += payload
                    if flags & 0x4:
                        self.headers(*block)
                        block = None
                    continue
                if kind in (0, 1, 3, 9) and sid == 0:
                    raise Malformed(f"frame type {kind} on stream 0")
                if kind == 0:  # DATA
                    self.data(sid, flags & 1, self.unpad(payload, flags))
                elif kind == 1:  # HEADERS
                    payload = self.unpad(payload, flags)
                    if flags & 0x20:  # PRIORITY
                        if len(payload) < 5:
                            raise Malformed("HEADERS shorter than its priority")
                        payload = payload[5:]
                    if flags & 0x4:  # END_HEADERS
                        self.headers(sid, flags & 1, payload)
                    else:
                        block = [sid, flags & 1, payload]
                elif kind == 9:
                    raise Malformed("CONTINUATION without HEADERS")
                elif kind == 3:  # RST_STREAM
                    self.reset(sid)
                elif kind == 4 and not flags & 1:  # SETTINGS
                    if sid != 0 or length % 6:
                        raise Malformed("a malformed SETTINGS")
                    with self.lock:
                        self.sock.sendall(self.frame(4, 1, 0, b""))
                elif kind == 5:
                    raise Malformed("PUSH_PROMISE with push off")
                elif kind == 6 and not flags & 1:  # PING
                    with self.lock:
                        self.sock.sendall(self.frame(6, 1, 0, payload))
                elif kind == 7:  # GOAWAY
                    self.goaway(struct.unpack(">I", payload[:4])[0] & 0x7FFFFFFF)
                # PRIORITY, WINDOW_UPDATE and unknown types change nothing here.
        except OSError as e:  # ConnectionError included
            self.fail_all(failure(e))
        except Exception as e:
            why = str(e) if isinstance(e, Malformed) else f"reader {type(e).__name__}: {e}"
            self.errors.append(why)
            self.fail_all(f"malformed: {why}", every=True)
        finally:
            self.inside = 0  # what the reader stopped on is in `errors`, or was between frames

    def stream(self, sid, what):
        """The open Stream `sid`, or None for one this client gave up on;
        Malformed for a stream never opened or already ended."""
        with self.lock:
            if sid in self.waiting:
                return self.waiting[sid]
            if sid % 2 == 0 or sid >= self.next_id:
                raise Malformed(f"{what} on stream {sid}, never opened")
            if self.ended.get(sid):
                return None
        raise Malformed(f"{what} on stream {sid}, already ended")

    def headers(self, sid, end, block):
        fields = self.hpack.decode(block)  # always: the table is the connection's
        stream = self.stream(sid, "HEADERS")
        if stream is None:
            return
        if stream.status is not None:
            try:
                if not end or any(name is not None and name.startswith(b":") for name, _ in fields):
                    raise Malformed("a header block after the response head, not trailers")
                for name, value in fields:
                    h2_field(name, value)
            except Malformed as e:
                self.finish(sid, f"malformed: {e}")
            else:
                self.finish(sid, self.outcome(stream))
            return
        try:
            status, length = h2_response_head(fields)
        except Malformed as e:
            self.finish(sid, f"malformed: {e}")
            return
        if 100 <= status < 200:
            if status == 101 or end:
                self.finish(sid, f"malformed: an interim {status} {'ending the stream' if end else ''}".strip())
            return
        stream.status, stream.length = status, length
        if end:
            self.finish(sid, self.outcome(stream))

    def data(self, sid, end, payload):
        stream = self.stream(sid, "DATA")
        if stream is None:
            return
        if stream.status is None:
            self.finish(sid, "malformed: DATA before HEADERS")
            return
        stream.body += payload
        if end:
            self.finish(sid, self.outcome(stream))

    def reset(self, sid):
        with self.lock:
            stream = self.waiting.get(sid)
        if stream is not None:
            self.finish(sid, self.cut(stream, "reset"))

    def goaway(self, last):
        """Ends the streams the server will not process, and refuses new
        ones; the others may still complete."""
        with self.lock:
            self.dead = "goaway"
            later = [(sid, stream) for sid, stream in self.waiting.items() if sid > last]
        for sid, stream in later:
            self.finish(sid, self.cut(stream, "goaway"))

    @staticmethod
    def cut(stream, reason):
        """`reason` for a stream that ended with it, or malformed once a frame
        of its response began to arrive."""
        return f"malformed: {reason} after its response began" if stream.begun else reason

    @staticmethod
    def outcome(stream):
        status, body = stream.status, stream.body
        if stream.length is not None and stream.length != len(body):
            return f"malformed: content-length {stream.length} with {len(body)} bytes of DATA"
        if status in (204, 304) and body:
            return f"malformed: DATA on a {status}"
        if status == 200 and not expected(stream.path, body):
            return f"malformed: body {body[:40]!r}"
        return status

    def decide(self, stream, outcome):
        """Gives `stream` its `outcome`, under the lock. Once `call` gave up
        on it, its outcome (a timeout) stays, and a malformed `outcome` goes
        to `late`: an answer that came too late is still checked."""
        if not stream.event.is_set():
            stream.outcome = outcome
            stream.event.set()
        elif is_malformed(outcome):
            self.late.append(f"{stream.path} after its {stream.outcome}: {outcome.removeprefix('malformed: ')}")

    def finish(self, sid, outcome):
        """Ends stream `sid` with `outcome`; frames may still come for a
        stream ended malformed or given up."""
        with self.lock:
            stream = self.waiting.pop(sid, None)
            if stream is None:
                return
            self.ended[sid] = stream.event.is_set() or is_malformed(outcome)
            self.decide(stream, outcome)

    def fail_all(self, reason, every=False):
        """Ends every open stream with `reason` (`cut`, unless `every`: then
        `errors` already holds it), and every later one too."""
        with self.lock:
            self.dead = reason
            streams = list(self.waiting.values())
            self.waiting.clear()
            for stream in streams:
                if every:
                    if not stream.event.is_set():
                        stream.outcome = reason
                        stream.event.set()
                else:
                    self.decide(stream, self.cut(stream, reason))

    def settle(self, grace):
        """Ends the connection at the end of the run, so that `errors` and
        `late` then hold every verdict it will give: waits up to `grace`
        seconds for its open streams (given up ones included) and a frame
        that began to arrive, then shuts the socket and waits for the
        reader to stop. A frame still not whole is then a connection error,
        and a stream whose response began is cut."""
        deadline = time.monotonic() + grace
        while (self.waiting or self.inside) and self.reader.is_alive() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.closing = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.reader.join()

    def call(self, path, timeout, note=None):
        stream = self.get(path, note)
        if not stream.event.wait(timeout):
            with self.lock:
                if not stream.event.is_set():
                    stream.outcome = self.cut(stream, "timeout")
                    stream.event.set()
        return stream.outcome


class Late:
    """HTTP/1.1 answers still owed when their request was given up: a
    timeout after the request was written, before any byte of the answer.
    Each is read on, in a thread of its own, and checked as any other is
    (`h1_read_response`, then `expect_eof` where the connection closes), so
    an answer that comes too late and broken still fails the run: `found`.
    The request's outcome stays the timeout."""

    def __init__(self):
        self.lock = threading.Lock()
        self.watched = []  # (thread, socket)
        self.found = []
        self.closing = False  # `settle` shut the sockets

    def watch(self, sock, path, close):
        """Reads the answer to `path` on `sock` (`close`: the request said
        `Connection: close`), then closes `sock`."""

        def read():
            try:
                sock.settimeout(None)
                _, fields, _ = h1_read_response(sock, path)
                if close or closes(fields):
                    expect_eof(sock)
                    if self.closing:
                        raise Malformed("the connection still open at the end of the run")
            except Malformed as e:
                with self.lock:
                    self.found.append(f"{path} after its timeout: {e}")
            except OSError:
                pass  # no answer by the end of the run: the request stays lost
            finally:
                sock.close()

        thread = threading.Thread(target=read, daemon=True)
        with self.lock:
            self.watched.append((thread, sock))
        thread.start()

    def settle(self, grace):
        """Waits up to `grace` seconds for the answers still owed, then
        shuts their sockets and waits for every reader, so that `found` then
        holds every verdict. An answer begun but not whole then is
        Malformed; one not begun stays lost."""
        deadline = time.monotonic() + grace
        while any(thread.is_alive() for thread, _ in self.watched) and time.monotonic() < deadline:
            time.sleep(0.01)
        self.closing = True
        for _, sock in self.watched:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        for thread, _ in self.watched:
            thread.join()


def owed(e, note):
    """Whether a request whose call raised `e` may still be answered: its
    write completed and it timed out before any byte of an answer."""
    return isinstance(e, socket.timeout) and "written" in note


class Pool:
    """HTTP/1.1 keep-alive connections; `bounded` caps them at `POOL`. An
    answer still owed after a timeout goes to `late`."""

    def __init__(self, port, bounded, late):
        self.port = port
        self.bounded = bounded
        self.late = late
        self.cond = threading.Condition()
        self.idle = [H1(port) for _ in range(POOL)]

    def take(self, timeout):
        deadline = time.monotonic() + timeout
        with self.cond:
            while not self.idle:
                if not self.bounded:
                    return None
                left = deadline - time.monotonic()
                if left <= 0 or not self.cond.wait(left):
                    raise socket.timeout()
            return self.idle.pop(0)

    def give_back(self, conn):
        with self.cond:
            if conn is not None:
                self.idle.append(conn)
            self.cond.notify()

    def probe(self, timeout, note):
        try:
            conn = self.take(timeout)
        except socket.timeout:
            return "pool-wait-timeout"
        if conn is None:
            try:
                conn = H1(self.port, ask_worker=False)
            except OSError as e:
                return "connect: " + failure(e)
        else:
            note["worker"] = conn.worker
            note["idle_ms"] = (time.monotonic() - conn.last) * 1000
        sock = conn.sock
        sock.settimeout(timeout)
        try:
            write(sock, h1_request("/health", False), note)
            status, fields, _ = h1_read_response(sock, "/health")
            note["answered"] = time.monotonic()
            if closes(fields):
                expect_eof(sock)
        except (OSError, Malformed) as e:
            if owed(e, note):
                self.late.watch(sock, "/health", False)
                self.drop(conn, close=False)
            else:
                self.drop(conn)
            return failure(e)
        except BaseException:
            self.drop(conn)
            raise
        if closes(fields):
            self.drop(conn)
        else:
            conn.last = time.monotonic()
            self.give_back(conn)
        return status

    def drop(self, conn, close=True):
        """Closes `conn` (unless not `close`) instead of giving it back; a
        bounded pool opens a replacement."""
        if close:
            conn.sock.close()
        self.give_back(None)
        if self.bounded:
            try:
                self.give_back(H1(self.port, ask_worker=False))
            except OSError:
                pass


def h1_new_call(port, path, timeout, note, late=None):
    """GET `path` on a new connection with `Connection: close`: its status,
    or why not (`failure`). Sets note["answered"] when the whole response
    has been read, before the wait for EOF. An answer still owed after a
    timeout goes to `late`, if given."""
    try:
        sock = h1_connect(port)
    except OSError as e:
        return "connect: " + failure(e)
    try:
        sock.settimeout(timeout)
        write(sock, h1_request(path, True), note)
        status = h1_read_response(sock, path)[0]
        note["answered"] = time.monotonic()
        # The request said `Connection: close`: nothing may follow the
        # response but EOF.
        expect_eof(sock)
        return status
    except (OSError, Malformed) as e:
        if late is not None and owed(e, note):
            late.watch(sock, path, True)
            sock = None
        return failure(e)
    finally:
        if sock is not None:
            sock.close()


def ask_worker(conn):
    """Asks `/worker` on `conn` and returns the worker number; raises unless
    the answer is whole (`h1_read_response`), 200, and keeps the connection
    open (no `Connection: close`)."""
    status, fields, body = conn.call("/worker")
    if status != 200:
        raise ValueError(f"/worker answered {status}")
    if any(b"close" in [t.strip() for t in v.lower().split(b",")] for v in fields.get(b"connection", [])):
        raise ValueError("/worker answered with Connection: close")
    return body


def spread_conn(port):
    """One HTTP/1.1 connection whose `/worker` answered as `ask_worker`
    requires; raises otherwise."""
    conn = H1(port, ask_worker=False)
    try:
        conn.worker = ask_worker(conn)
    except BaseException:
        conn.sock.close()
        raise
    return conn


def spread(port):
    """Opens `SPREAD` keep-alive HTTP/1.1 connections one after another, each
    asking `/worker` before the next is opened, then `SPREAD` more from
    `SPREAD` threads released together by a barrier. Once all are open it
    asks `/worker` again on every one, so a connection counts only if it was
    still open, is reused, and names the same worker: the counts are of
    connections held open at once. Prints, for each phase, how many landed on
    each worker, busiest first, and how many of the `SPREAD` counted. Any
    failure makes the counts no measurement: it prints the failures and
    returns 1."""
    kept, failed = [], []
    for _ in range(SPREAD):
        try:
            kept.append(spread_conn(port))
        except Exception as e:
            failed.append(f"sequential: {e!r}")
    barrier = threading.Barrier(SPREAD)
    together = []
    lock = threading.Lock()

    def connect():
        try:
            barrier.wait()
            conn = spread_conn(port)
        except BaseException as e:
            with lock:
                failed.append(f"concurrent: {e!r}")
            return
        with lock:
            together.append(conn)

    threads = [threading.Thread(target=connect) for _ in range(SPREAD)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    def still_open(phase, conns):
        held = []
        for conn in conns:
            try:
                again = ask_worker(conn)
                if again != conn.worker:
                    raise ValueError(f"worker {conn.worker!r} became {again!r}")
                held.append(conn)
            except Exception as e:
                failed.append(f"{phase}, asked again: {e!r}")
        return held

    held_kept, held_together = still_open("sequential", kept), still_open("concurrent", together)

    def order(conns):
        counts = {}
        for conn in conns:
            counts[conn.worker] = counts.get(conn.worker, 0) + 1
        return "/".join(str(n) for n in sorted(counts.values(), reverse=True))

    print(f"spread sequential={order(held_kept)} ({len(held_kept)} of {SPREAD} held open) "
          f"concurrent={order(held_together)} ({len(held_together)} of {SPREAD} held open)", flush=True)
    for conn in kept + together:
        if n := pending(conn.sock):
            failed.append(f"{n} bytes after the last response on a connection")
        conn.sock.close()
    for f in failed:
        print(f"  failed {f}", flush=True)
    return 1 if failed else 0


def capacity(port, held, slow_ms, signal_path):
    """Holds `held` handlers at once and asks `/health` on a new connection
    while they run. Each `GET /slow/SLOW_MS` goes on a new HTTP/1.1
    connection, opened only once the previous one's handler has signalled
    its start, so the held workers no longer poll and the next connection
    goes to a worker that does; then `/health` goes on a new connection.
    Prints `capacity held=<n> health=<status> during=<yes if answered
    before the first held handler signalled its end, and when none is held>
    health_ms=<from sending> margin_ms=<that first end minus the answer, as
    this client read them; near 0 is a tie> slow=<each slow request's
    status>`; exits nonzero if the handlers do not signal, if one ended
    before all were held (the next connection went to a held worker), or if
    a request is not answered 200, a client error and a malformed response
    included."""
    fd = os.open(signal_path, os.O_RDWR)
    times = []  # (byte, when it arrived), appended by the reader as it reads
    arrived = threading.Condition()

    def read_signal():
        # O_RDWR keeps a writer present, so this read never sees EOF (Linux).
        while len(times) < 2 * held:
            byte = os.read(fd, 1).decode()
            with arrived:
                times.append((byte, time.monotonic()))
                arrived.notify_all()

    threading.Thread(target=read_signal, daemon=True).start()
    starts = lambda: [b for b, _ in times].count("s")
    # One slot per request, so a client thread that raises leaves a mark
    # instead of a missing entry that the final check would not see.
    slow = [None] * held

    def call(i, note):
        try:
            slow[i] = h1_new_call(port, f"/slow/{slow_ms}", slow_ms / 1000 + ANSWER_BOUND_S, note)
        except Exception as e:
            slow[i] = f"{type(e).__name__}: {e}"

    threads = []
    for i in range(held):
        t = threading.Thread(target=call, args=(i, {}), daemon=True)
        t.start()
        threads.append(t)
        with arrived:
            if not arrived.wait_for(lambda: starts() == i + 1, ANSWER_BOUND_S):
                sys.exit(f"capacity: handler {i + 1} of {held} did not signal its start: {times}")
    with arrived:
        if any(b == "e" for b, _ in times):
            sys.exit(f"capacity: a handler ended before {held} were held: {times}")
    note = {}
    status = h1_new_call(port, "/health", slow_ms / 1000 + ANSWER_BOUND_S, note)
    done = note.get("answered", time.monotonic())
    for t in threads:
        t.join()
    with arrived:
        if not arrived.wait_for(lambda: len(times) == 2 * held, ANSWER_BOUND_S):
            sys.exit(f"capacity: the held handlers did not signal their ends: {times}")
    ends = [at for b, at in times if b == "e"]
    during = "yes" if not ends or done < min(ends) else "no"
    margin = f"{(min(ends) - done) * 1000:.1f}" if ends else "none"
    health_ms = (done - note["sent"]) * 1000 if "sent" in note else float("nan")
    print(
        f"capacity held={held} health={status} during={during} health_ms={health_ms:.0f} margin_ms={margin} "
        f"slow={','.join(str(s) for s in slow) or 'none'}",
        flush=True,
    )
    if status != 200 or any(s != 200 for s in slow):
        sys.exit("capacity: a request was not answered 200")


class Signal:
    """Reads the slow handler's `s` and `e` from the FIFO, with the time each
    arrived."""

    def __init__(self, path):
        # O_RDWR keeps a writer present, so the server's open never blocks
        # and this read never sees EOF between the two bytes (Linux).
        self.fd = os.open(path, os.O_RDWR)
        self.times = {}
        self.done = threading.Event()
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        while len(self.times) < 2:
            byte = os.read(self.fd, 1).decode()
            self.times[byte] = time.monotonic()
        self.done.set()


def main():
    port, mode, slow_ms, signal_path = int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4]
    if mode == "spread":
        return spread(port)
    if mode.startswith("capacity-"):
        return capacity(port, int(mode.removeprefix("capacity-")), slow_ms, signal_path)
    control = slow_ms == 0
    slow_s = slow_ms / 1000 if not control else CONTROL_S
    end_s = HOLD_AT_S + slow_s + TAIL_S
    bound_s = HOLD_AT_S + slow_s + ANSWER_BOUND_S
    signal = None if control else Signal(signal_path)

    slow_conn = None  # (worker, call)
    kept_open = lambda: []  # the HTTP/1.1 connections open at the end
    h2_conns = []
    late = Late()
    if mode == "h1-new":
        probe = lambda t, note: h1_new_call(port, "/health", t, note, late)
    elif mode in ("h1-pool", "h1-pool-fixed"):
        pool = Pool(port, mode == "h1-pool-fixed", late)
        probe = pool.probe
        kept_open = lambda: [conn.sock for conn in pool.idle]
    elif mode in ("h2c-same", "h2c-other"):
        conn = H2c(port)
        probe_conn = conn
        h2_conns.append(conn)

        def probe(t, note):
            note["worker"] = probe_conn.worker
            return probe_conn.call("/health", t, note)

        if mode == "h2c-other":
            conn = H2c(port)
            h2_conns.append(conn)
        slow_conn = (conn.worker, lambda t: conn.call(f"/slow/{slow_ms}", t))
    else:
        sys.exit(f"unknown mode {mode}")
    if slow_conn is None and not control:
        h1 = H1(port)
        h1_owed = []
        pool_open = kept_open
        kept_open = lambda: pool_open() + ([] if h1_owed else [h1.sock])

        def slow_call(t):
            h1.sock.settimeout(t)
            note = {}
            try:
                write(h1.sock, h1_request(f"/slow/{slow_ms}", False), note)
                status, fields, _ = h1_read_response(h1.sock, f"/slow/{slow_ms}")
                if closes(fields):
                    expect_eof(h1.sock)
                return status
            except (OSError, Malformed) as e:
                if owed(e, note):
                    h1_owed.append(True)
                    late.watch(h1.sock, f"/slow/{slow_ms}", False)
                return failure(e)

        slow_conn = (h1.worker, slow_call)

    start = time.monotonic()
    # One dict per probe: started, sent (absent if never sent), done (when
    # answered or failed), outcome (200 or why not), and for kept-open
    # connections worker and idle_ms.
    results = []
    lock = threading.Lock()
    slow_result = []

    def run_probe():
        note = {"started": time.monotonic()}
        try:
            note["outcome"] = probe(max(0.1, start + bound_s - note["started"]), note)
        except Exception as e:  # recorded, so the run fails instead of losing the probe
            note["outcome"] = f"client error: {type(e).__name__}: {e}"
        note["done"] = note.get("answered", time.monotonic())
        with lock:
            results.append(note)

    def run_slow():
        try:
            slow_result.append(slow_conn[1](max(0.1, bound_s)))
        except Exception as e:
            slow_result.append(f"client error: {type(e).__name__}: {e}")

    threads = []
    probe_at = 0.0
    slow_sent = control
    while probe_at < end_s:
        now = time.monotonic() - start
        if not slow_sent and now >= HOLD_AT_S:
            threads.append(threading.Thread(target=run_slow))
            threads[-1].start()
            slow_sent = True
            continue
        if now >= probe_at:
            threads.append(threading.Thread(target=run_probe))
            threads[-1].start()
            probe_at += PERIOD_S
            continue
        next_at = probe_at if slow_sent else min(probe_at, HOLD_AT_S)
        time.sleep(max(0.0, next_at - now))
    for t in threads:
        t.join()

    if control:
        hold_from, hold_to = start + HOLD_AT_S, start + HOLD_AT_S + CONTROL_S
        slow_outcome, slow_worker = "none", None
    else:
        if not signal.done.wait(ANSWER_BOUND_S) or set(signal.times) != {"s", "e"}:
            sys.exit(f"{mode}: the slow handler did not signal its start and end: {signal.times}")
        hold_from, hold_to = signal.times["s"], signal.times["e"]
        slow_outcome, slow_worker = slow_result[0], slow_conn[0]
    ok = lambda r: r["outcome"] == 200
    spoils = lambda outcome: is_malformed(outcome) or str(outcome).startswith("client error: ")
    is_lost = lambda r: "written" in r and not ok(r) and not spoils(r["outcome"])
    count = lambda rs: f"{len(rs)}/{sum(map(is_lost, rs))}/{sum('write_failed' in r for r in rs)}"
    window = [r for r in results if "sent" in r and hold_from <= r["sent"] < hold_to]
    answered = sorted(r["done"] - r["sent"] for r in window if ok(r))
    during = sum(1 for r in window if ok(r) and r["done"] < hold_to)
    lost = [r for r in window if is_lost(r)]
    lost_kinds = sorted({str(r["outcome"]) for r in lost})
    write_failed = [r for r in window if "write_failed" in r]
    started = [r for r in results if hold_from <= r["started"] < hold_to]
    sent_after = [r for r in started if "sent" in r and r["sent"] >= hold_to]
    not_sent = [r for r in results if "sent" not in r]
    p50 = answered[len(answered) // 2] * 1000 if answered else float("nan")
    worst = answered[-1] * 1000 if answered else float("nan")
    line = (
        f"{mode} n={len(window)} during={during} after={len(answered) - during} "
        f"lost={len(lost)} write_failed={len(write_failed)} p50_ms={p50:.0f} max_ms={worst:.0f} slow={slow_outcome} "
        f"hold_ms={(hold_to - hold_from) * 1000:.0f} started={len(started)} "
        f"sent_after={count(sent_after)} not_sent={len(not_sent)}"
    )
    if mode != "h1-new" and not control:
        known = [r for r in window if r.get("worker") is not None]
        same = [r for r in known if r["worker"] == slow_worker]
        other = [r for r in known if r["worker"] != slow_worker]
        line += f" slow_worker={count(same)} other_workers={count(other)}"
    idles = sorted(r["idle_ms"] for r in lost if "idle_ms" in r)
    if idles:
        line += f" lost_idle_ms={idles[0]:.0f}..{idles[-1]:.0f}"
    if lost_kinds:
        line += f" lost_as={','.join(lost_kinds)}"
    if write_failed:
        line += f" write_failed_as={','.join(sorted({r['write_failed'] for r in write_failed}))}"
    if not_sent:
        line += f" not_sent_as={','.join(sorted({str(r['outcome']) for r in not_sent}))}"
    why = lambda outcome: str(outcome).removeprefix("malformed: ")
    malformed = [why(r["outcome"]) for r in results if is_malformed(r["outcome"])]
    if is_malformed(slow_outcome):
        malformed.append(f"slow: {why(slow_outcome)}")
    for sock in kept_open():
        if n := pending(sock):
            malformed.append(f"{n} bytes after the last response on a kept-open connection")
    for conn in h2_conns:
        conn.settle(1.0)
        malformed += [f"connection: {e}" for e in conn.errors] + [f"late: {e}" for e in conn.late]
    late.settle(1.0)
    malformed += [f"late: {e}" for e in late.found]
    if malformed:
        line += f" malformed={len(malformed)} malformed_as={';'.join(sorted(set(malformed)))}"
    errors = [str(o) for o in [r["outcome"] for r in results] + [slow_outcome] if str(o).startswith("client error: ")]
    if errors:
        line += f" client_errors={len(errors)} client_errors_as={';'.join(sorted(set(errors)))}"
    print(line, flush=True)
    return 1 if malformed or errors else 0


if __name__ == "__main__":
    sys.exit(main())
