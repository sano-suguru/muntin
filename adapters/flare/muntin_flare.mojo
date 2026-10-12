"""Flare transport adapter for Muntin (M1-002). Not part of Muntin core.

Depends inward on Muntin's backend seam, `App.handle(Request) -> Response`,
and never routes on its own. Builds only in the `flare` pixi environment.

Conversion policy (M1; target handling restated for M2-002; headers M3-005,
decided in docs/history/architecture-decisions.md "Headers decision (M3-002)"):
- method and request target (M3-039, decided in
  docs/history/architecture-decisions.md "Request target and method bytes
  decision (M3-039)"): Flare's `method` and `url` (path plus any query,
  undecoded) copied byte for byte with `String(from_utf8=)` from their
  `as_bytes()` spans, so only when they are well-formed UTF-8. Over
  cleartext HTTP/2 Flare v0.12.0 builds both from the HPACK octets with
  `String(unsafe_from_utf8=)`, so they can hold bytes that are not UTF-8,
  and a `String` slice that starts inside such a sequence aborts the
  process (Mojo 1.1.0's code point boundary assertion). Neither is
  searched, split or sliced before the check: such a method or target
  cannot be represented, and the answer is 400 before `App.handle`, as for
  a header field. `_serve_app`'s comparison with `HEAD` compares bytes and
  runs first. Muntin's `Request` then splits path from query, exactly as
  for the in-memory backend. The adapter does not split, parse or decode
  the query, and does not use Flare's query helpers.
- request body (M3-040, decided in docs/history/architecture-decisions.md
  "Binary request and response bodies decision (M3-040)", which replaced
  M3-038's refusal): Flare's raw body bytes copied into `Request.body`,
  whatever they are, so it holds exactly the bytes received (a U+FFFD the
  client sent, NUL and bytes that are not UTF-8 included); nothing is
  validated or refused here. A typed text body that is not UTF-8 is
  `App.handle`'s 400, after routing and middleware. Flare's
  `Request.text()` is not used: it replaces bytes that are not UTF-8 with
  U+FFFD.
- request headers: every field, in order and casing, rebuilt from Flare's
  public `HeaderMap.encode_to` (Flare has no public field iterator) and
  verified against Flare's by-name view: the parsed count is `len()`, and
  per name the parsed values equal `get_all(name)` position by position.
  Over HTTP/1.1 the parse is exact. Over cleartext HTTP/2, Flare v0.11.0
  admitted a name with `:` inside, which a first-colon parse would misread
  as another field; v0.12.0 refuses it, and the check does not rely on
  that. Over HTTP/2 Flare v0.12.0 passes a value's bytes through unchanged,
  so a value that is not UTF-8 fails the check. A field that fails the
  check or `Headers.add` (a control byte, a non-token name, a value that
  is not UTF-8) cannot be represented: the answer is 400.
- version and peer: dropped.
- response: status, body bytes (whatever they are; M3-040) and header
  fields copied; no `Content-Type` is added or changed; reason left unset,
  so Flare's default applies. Header fields go out in order, except those
  the backend owns or that are connection-specific (`Content-Length`,
  `Transfer-Encoding`, `Connection`, `Keep-Alive`, `Proxy-Connection`,
  `Upgrade`, `TE`, `Trailer`) and every field a `Connection` value names:
  Flare filters a different subset on each protocol, so the adapter applies
  one rule for both. Each field is re-checked with `Headers.add` before it
  is handed to Flare; a failure answers 500.
- `HEAD` (M3-027, decided in docs/history/architecture-decisions.md "HEAD
  decision (M3-026)"): `App.handle` answers a `HEAD` request through `GET`
  routes, body included; the backend keeps the content off the wire. For a request
  whose method is `HEAD`, `_serve_app` (which both handlers call) takes the
  response it would send at every exit (`App.handle`'s answer, `to_flare_response`'s fixed
  500, its own 400) and sends its status and fields with no body, declaring
  a `Content-Length` equal to the body's byte length, except for a status
  that never carries content (1xx, 204, 205, 304), where it declares none.
  Flare v0.12.0 would send the content over cleartext HTTP/2, and over
  HTTP/1.1 frames an empty body as `Content-Length: 0`, so both steps are
  the adapter's; over HTTP/1.1 Flare still frames a 205 or 304 with
  `Content-Length: 0` itself. A handler's own `Content-Length` is still
  dropped. Every other method is unchanged.

Serving (M3-033, decided in docs/history/architecture-decisions.md "Serving
entrypoint decision (M3-032)"): `Server.bind(host, port)` checks that `port`
is 0 to 65535 (`port out of range: <port>` otherwise, before anything is
parsed or bound), then binds and listens on `host`, an IPv4 or IPv6 literal
(Flare's `IpAddr.parse`: no name resolution), with `_server_config`'s
`ServerConfig`. A bind failure raises; dropping the `Server` closes its
listener. `server.port()` is the bound port. `server.serve(app)` borrows
`app` and runs Flare's single-worker `serve` on the calling thread with
`_BorrowedHandler`, which answers through `_serve_app` as `MuntinHandler`
does; a raise propagates and a return returns, with no policy of its own.
It returns after a graceful stop (below) or when the reactor stopped on a
failed poll. There is no stop call, worker count or backend configuration
other than the body limit and the grace window below.
`_BorrowedHandler` is not `Copyable`, which keeps Flare's multi-worker
`serve` out of reach. `Server`'s one initializer takes keyword-only `_host`,
`_port` and `_max_body_bytes`, so `Server.bind` is the one public spelling.
`MuntinHandler` stays for the adapter's own tests and probes.

Receive body limit (M3-044, decided in docs/history/architecture-decisions.md
"Server receive body limit decision (M3-044)"): `Server.bind`'s keyword-only
`max_body_bytes` (10 MiB, Flare v0.12.0's default, when not given) bounds
the request body Flare receives: no longer body is received or reaches the
adapter. It is a bound, not a promise to accept every body within it: over
HTTP/1.1 Flare also counts a request's head, chunk framing and pipelined
bytes (below). `_server_config` checks it, after the
port and before the host is parsed (0 to 2^59 - 1, above which Flare's
chunk-size scanner can overflow; `max_body_bytes out of range: <value>`
otherwise), and writes it into both of Flare's fields, `max_body_size`
(HTTP/1.1) and `h2.max_body_size` (HTTP/2, which the first does not reach);
every other field keeps Flare's default. Flare refuses a longer body itself,
before the adapter, with its own answers (docs/DX.md section 1: over
HTTP/1.1 413 or 400 and a closed connection, also counting a chunked body's
framing; over h2c a reset stream). It is not
`FromBytes.max_bytes` or `Json[T]`'s cap, which `App.handle` checks on a
body already received. `Server.serve` refuses to start when the environment
selects Flare's opt-in `FLARE_BUFRING_HANDLER=1` loop, which is not
supported (docs/DX.md section 1).

Graceful shutdown (M3-045, decided in docs/history/architecture-decisions.md
"Graceful shutdown decision (M3-045)"): while `serve` runs, SIGTERM and
SIGINT stop it. `_StopWatch` installs `_stop_signal_seen`, a handler that
does nothing, with `SA_RESETHAND`, so a delivered signal only resets its
disposition to `SIG_DFL`; a watcher thread (`_watch_for_stop`) sees that,
resets the other signal too (a second one takes the default action) and
calls Flare's `drain` with `Server.bind`'s `shutdown_grace_ms` (0 to
86,400,000; 5000 when not given, Flare v0.12.0's default, kept in
`ServerConfig.shutdown_timeout_ms`): the listener closes, the open
connections are served for the whole window, then Flare closes them and its
`serve` returns. A handler still running `_REACTOR_STOP_MS` after the window
ends the process with 128 + the signal. When `serve` returns or raises, the
watcher is joined and both dispositions are put back. What clients see:
docs/DX.md section 1.
"""

from std.atomic import Atomic, Ordering
from std.ffi import c_int, external_call
from std.os import getenv
from std.sys import CompilationTarget

from flare.http import (
    Handler,
    HttpServer,
    Request as FlareRequest,
    Response as FlareResponse,
    ServerConfig,
)
from flare.net import IpAddr, SocketAddr
from flare.runtime import libc_nanosleep_ms, monotonic_now_ms
from flare.runtime._thread import ThreadHandle, _OpaquePtr
from flare.utils import exit, getpid, kill
from muntin import App, Headers, Request, Response


def _ascii_lower(s: String) -> String:
    var out = String()
    for b in s.as_bytes():
        var c = Int(b)
        if c >= ord("A") and c <= ord("Z"):
            out += chr(c + 32)
        else:
            out += chr(c)
    return out^


def _same_name(a: String, b: String) -> Bool:
    return a.byte_length() == b.byte_length() and _ascii_lower(
        a
    ) == _ascii_lower(b)


def _trim_ows(s: StringSlice) -> String:
    var b = s.as_bytes()
    var start = 0
    var end = len(b)
    while start < end and (Int(b[start]) == 32 or Int(b[start]) == 9):
        start += 1
    while end > start and (Int(b[end - 1]) == 32 or Int(b[end - 1]) == 9):
        end -= 1
    return String(s[byte=start:end])


def to_muntin_headers(request: FlareRequest) raises -> Headers:
    """Exactly the request's fields, or a raise when they cannot be
    represented."""
    var buf = List[UInt8]()
    request.headers.encode_to(buf)
    var text = String(from_utf8_lossy=Span(buf))
    var names = List[String]()
    var values = List[String]()
    for line in text.split("\r\n"):
        if line.byte_length() == 0:
            continue
        var colon = line.find(":")
        if colon <= 0:
            raise Error("unparsable header line")
        names.append(String(line[byte=:colon]))
        if line.byte_length() >= colon + 2:
            values.append(String(line[byte = colon + 2 :]))
        else:
            values.append(String())
    if len(names) != request.headers.len():
        raise Error("header count mismatch")
    var headers = Headers()
    for i in range(len(names)):
        var seen = 0
        for j in range(i):
            if _same_name(names[j], names[i]):
                seen += 1
        var flare_values = request.headers.get_all(names[i])
        if seen >= len(flare_values) or flare_values[seen] != values[i]:
            raise Error("header field cannot be represented")
        headers.add(names[i], values[i])
    return headers^


def to_muntin_request(request: FlareRequest) raises -> Request:
    """Exactly the request's method, target, body and fields, or a raise
    when the method, target or fields cannot be represented.
    `String(from_utf8=)` keeps well-formed UTF-8 byte for byte and raises on
    anything else. The method and target are checked through their byte
    spans before `Request` splits the target, because a slice of a `String`
    that is not UTF-8 can abort (M3-039). The body is a copy of Flare's raw
    bytes, whatever they are, never `Request.text()`, which replaces bytes
    that are not UTF-8 with U+FFFD (M3-040)."""
    return Request(
        String(from_utf8=request.method.as_bytes()),
        String(from_utf8=request.url.as_bytes()),
        request.body.copy(),
        to_muntin_headers(request),
    )


def _backend_owned(name: String) -> Bool:
    var lower = _ascii_lower(name)
    return (
        lower == "content-length"
        or lower == "transfer-encoding"
        or lower == "connection"
        or lower == "keep-alive"
        or lower == "proxy-connection"
        or lower == "upgrade"
        or lower == "te"
        or lower == "trailer"
    )


def _internal_error() -> FlareResponse:
    return FlareResponse(
        status=500, body=List(String("Internal Server Error").as_bytes())
    )


def to_flare_response(response: Response) -> FlareResponse:
    var out = FlareResponse(status=response.status, body=response.body.copy())
    var nominated = List[String]()
    for value in response.headers.get_all("connection"):
        for token in value.split(","):
            var name = _trim_ows(token)
            if name.byte_length() > 0:
                nominated.append(name)
    for i in range(len(response.headers)):
        var name = response.headers.name(i)
        var value = response.headers.value(i)
        var omit = _backend_owned(name)
        for n in nominated:
            if _same_name(name, n):
                omit = True
        if omit:
            continue
        try:
            # Second line: `Headers` fields are valid unless written
            # through an internal name; re-check before Flare sees them.
            var check = Headers()
            check.add(name, value)
            out.headers.append(name, value)
        except:
            return _internal_error()
    return out^


def _without_content(var response: FlareResponse) -> FlareResponse:
    """`response` as the answer to a `HEAD` request: its status and fields,
    no body, and a `Content-Length` equal to the body's byte length unless
    the status never carries content (1xx, 204, 205, 304)."""
    var length = len(response.body)
    response.body = List[UInt8]()
    var status = response.status
    var informational = status >= 100 and status <= 199
    if not informational and status != 204 and status != 205 and status != 304:
        try:
            response.headers.append("Content-Length", String(length))
        except:
            pass  # `append` rejects only CR and LF, which neither part has.
    return response^


def _answer(app: App, request: FlareRequest) -> FlareResponse:
    var muntin_request: Request
    try:
        muntin_request = to_muntin_request(request)
    except:
        return FlareResponse(
            status=400, body=List(String("Bad Request").as_bytes())
        )
    return to_flare_response(app.handle(muntin_request))


def _serve_app(app: App, request: FlareRequest) -> FlareResponse:
    """`app`'s answer to `request` as the adapter sends it: the conversion,
    `App.handle`, the adapter's 400 and 500, and the `HEAD` rule. Every
    handler in this module answers through it."""
    if request.method == "HEAD":
        return _without_content(_answer(app, request))
    return _answer(app, request)


struct MuntinHandler(Handler):
    """Serves a Muntin `App` as a Flare handler."""

    var app: App

    def __init__(out self, var app: App):
        self.app = app^

    def serve(self, request: FlareRequest) -> FlareResponse:
        return _serve_app(self.app, request)


struct _BorrowedHandler[origin: Origin[mut=False]](Handler):
    """Serves a borrowed `App` as a Flare handler, for `Server.serve`. Not
    `Copyable` on purpose: Flare's multi-worker `serve` requires it."""

    var _app: Pointer[App, Self.origin]

    def __init__(out self, ref[Self.origin] app: App):
        self._app = Pointer(to=app)

    def serve(self, request: FlareRequest) -> FlareResponse:
        return _serve_app(self._app[], request)


comptime _DEFAULT_MAX_BODY_BYTES = 10 * 1024 * 1024
"""`Server.bind`'s receive body limit when none is given: Flare v0.12.0's
default for both protocols, written here so that a Flare upgrade does not
change it (M3-044)."""

comptime _LARGEST_MAX_BODY_BYTES = Int.MAX >> 4
"""2^59 - 1: the largest receive body limit Flare v0.12.0's chunk-size scanner
handles without overflowing (it multiplies before it compares; with 2^59 or
`Int.MAX` one chunk-size line aborted the serving process, M3-044)."""


comptime _BUFRING_UNSUPPORTED = (
    "FLARE_BUFRING_HANDLER=1 is unsupported by Muntin with Flare v0.12.0"
)
"""What `Server.serve` raises, before serving, when the environment sets
`FLARE_BUFRING_HANDLER=1`, which selects Flare's unsupported buffer-ring loop
(M3-044; why: docs/DX.md section 1)."""


comptime _DEFAULT_SHUTDOWN_GRACE_MS = 5000
"""`Server.bind`'s grace window when none is given: Flare v0.12.0's
`ServerConfig.shutdown_timeout_ms` default, written here so that a Flare
upgrade does not change it (M3-045)."""

comptime _LARGEST_SHUTDOWN_GRACE_MS = 86_400_000
"""One day, the largest grace window `Server.bind` takes (M3-045)."""

comptime _REACTOR_STOP_MS = 1000
"""How long the watcher waits, after the grace window, for Flare's reactor to
leave its loop before it ends the process with 128 + the signal. The reactor
reads its stop flag at least every 100 ms, but not while a handler runs."""

comptime _WATCH_POLL_MS = 50
"""How often the watcher looks for a stop signal."""

comptime _SIGINT = 2
comptime _SIGTERM = 15
comptime _SIGACTION_BYTES = 256
"""Room for a `struct sigaction` on every supported system (152 bytes on
Linux glibc, 16 on macOS). The handler is its first word on both."""
comptime _SA_FLAGS_OFFSET = 12 if CompilationTarget.is_macos() else 136
comptime _SA_RESTART_RESETHAND = (
    0x2 | 0x4 if CompilationTarget.is_macos() else 0x10000000 | 0x80000000
)
"""`SA_RESTART | SA_RESETHAND`: interrupted system calls restart, and the
kernel resets the disposition to `SIG_DFL` as it delivers the signal."""

comptime _CB_DONE = 0
"""Control block cell: 1 once Flare's `serve` has returned or raised."""
comptime _CB_SERVER = 1
"""Control block cell: the address of the serving `HttpServer`."""
comptime _CB_GRACE = 2
"""Control block cell: the grace window, in milliseconds."""
comptime _CB_SIGNAL = 3
"""Control block cell: the stop signal the watcher acted on, or 0."""
comptime _CB_LEN = 4


def _stop_signal_seen(sig: c_int) abi("C"):
    """The handler `Server.serve` installs for SIGTERM and SIGINT. It does
    nothing: with `SA_RESETHAND` the kernel resets the disposition to
    `SIG_DFL` as it delivers the signal, and that reset is the notification
    the watcher reads. No allocation, lock, raise, global or Flare or Mojo
    object is touched in signal context (M3-045)."""
    pass


def _sigaction(sig: Int, new: Int, old: Int) -> Int:
    """`sigaction(2)` with both `struct sigaction` pointers as addresses (0 is
    NULL)."""
    return Int(external_call["sigaction", c_int](c_int(sig), new, old))


def _cell(
    block: Int, i: Int
) -> Pointer[Scalar[DType.int64], MutUntrackedOrigin]:
    return Pointer[Int64, MutUntrackedOrigin](
        unsafe_from_address=block + 8 * i
    ).unsafe_bitcast[Scalar[DType.int64]]()


def _load(block: Int, i: Int) -> Int:
    return Int(Atomic[Int64].load[ordering=Ordering.ACQUIRE](_cell(block, i)))


def _store(block: Int, i: Int, value: Int):
    Atomic[Int64].store[ordering=Ordering.RELEASE](
        _cell(block, i), Int64(value)
    )


def _watch_for_stop(arg: _OpaquePtr) -> _OpaquePtr:
    """The watcher thread `Server.serve` runs beside Flare's reactor (M3-045).

    Every `_WATCH_POLL_MS` it reads the dispositions of SIGTERM and SIGINT;
    one that is back to `SIG_DFL` was delivered. It then resets the other to
    `SIG_DFL` too, so a second stop signal ends the process by the default
    action, and calls Flare's `drain` with the grace window, which closes the
    listener, keeps the reactor serving the open connections for the whole
    window and then sets its stop flag. If the reactor has not left its loop
    `_REACTOR_STOP_MS` later (a handler still running), it ends the process
    with status 128 + the signal. It returns when the serving thread marks
    `_CB_DONE`. Never raises (a pthread start routine)."""
    var block = Int(arg)
    var seen = List[UInt8](length=_SIGACTION_BYTES, fill=0)
    var sig = 0
    while sig == 0:
        if _load(block, _CB_DONE) != 0:
            return arg
        for candidate in [_SIGTERM, _SIGINT]:
            _ = _sigaction(candidate, 0, Int(seen.unsafe_ptr()))
            if sig == 0 and seen.unsafe_ptr().unsafe_bitcast[Int]()[] == 0:
                sig = candidate
        if sig == 0:
            _ = libc_nanosleep_ms(_WATCH_POLL_MS)
    _store(block, _CB_SIGNAL, sig)
    var default = List[UInt8](length=_SIGACTION_BYTES, fill=0)
    _ = _sigaction(_SIGTERM, Int(default.unsafe_ptr()), 0)
    _ = _sigaction(_SIGINT, Int(default.unsafe_ptr()), 0)
    var server = Pointer[HttpServer, MutUntrackedOrigin](
        unsafe_from_address=_load(block, _CB_SERVER)
    )
    try:
        _ = server[].drain(_load(block, _CB_GRACE))
    except:
        server[].close()
    var deadline = monotonic_now_ms() + _REACTOR_STOP_MS
    while _load(block, _CB_DONE) == 0:
        if monotonic_now_ms() >= deadline:
            exit(128 + sig)
        _ = libc_nanosleep_ms(5)
    _ = seen^
    _ = default^
    return arg


def _restore_dispositions(previous: Int):
    """Puts back the SIGTERM and SIGINT dispositions saved at `previous`."""
    _ = _sigaction(_SIGTERM, previous, 0)
    _ = _sigaction(_SIGINT, previous + _SIGACTION_BYTES, 0)


struct _StopWatch(Movable):
    """What `Server.serve` sets up around Flare's `serve` and undoes after it
    (M3-045): the stop handler on SIGTERM and SIGINT, the dispositions it
    replaced, and the watcher thread with its control block. The block and
    the server it points to outlive the thread, which `finish` joins."""

    var _block: List[Int64]
    var _previous: List[UInt8]
    var _watcher: ThreadHandle

    def __init__(out self, server_addr: Int, grace_ms: Int) raises:
        self._block = List[Int64](length=_CB_LEN, fill=0)
        var block = Int(self._block.unsafe_ptr())
        _store(block, _CB_SERVER, server_addr)
        _store(block, _CB_GRACE, grace_ms)
        var handler: def(c_int) thin abi("C") -> None = _stop_signal_seen
        var action = List[UInt8](length=_SIGACTION_BYTES, fill=0)
        var at = action.unsafe_ptr()
        at.unsafe_bitcast[Int]()[] = Pointer(to=handler).unsafe_bitcast[Int]()[]
        at.unsafe_offset(_SA_FLAGS_OFFSET).unsafe_bitcast[Int32]()[] = Int32(
            _SA_RESTART_RESETHAND
        )
        self._previous = List[UInt8](length=2 * _SIGACTION_BYTES, fill=0)
        var previous = Int(self._previous.unsafe_ptr())
        _ = _sigaction(_SIGTERM, Int(at), previous)
        _ = _sigaction(_SIGINT, Int(at), previous + _SIGACTION_BYTES)
        _ = action^
        try:
            self._watcher = ThreadHandle.spawn_os[_watch_for_stop](
                _OpaquePtr(unsafe_from_address=block)
            )
        except e:
            _restore_dispositions(previous)
            raise e^

    def finish(mut self) raises -> Int:
        """Marks serving done, joins the watcher and puts the dispositions
        `__init__` replaced back. Returns the stop signal the watcher acted
        on, or 0. A stop signal that arrived too late for the watcher (its
        disposition is `SIG_DFL` but the watcher did not act) is sent again
        once the previous dispositions are back, so it is not lost."""
        var block = Int(self._block.unsafe_ptr())
        _store(block, _CB_DONE, 1)
        self._watcher.join()
        var acted = _load(block, _CB_SIGNAL)
        var missed = 0
        if acted == 0:
            var seen = List[UInt8](length=_SIGACTION_BYTES, fill=0)
            for sig in [_SIGTERM, _SIGINT]:
                _ = _sigaction(sig, 0, Int(seen.unsafe_ptr()))
                if (
                    missed == 0
                    and seen.unsafe_ptr().unsafe_bitcast[Int]()[] == 0
                ):
                    missed = sig
            _ = seen^
        _restore_dispositions(Int(self._previous.unsafe_ptr()))
        if missed != 0:
            _ = kill(getpid(), missed)
        return acted


def _server_config(
    max_body_bytes: Int, shutdown_grace_ms: Int = _DEFAULT_SHUTDOWN_GRACE_MS
) raises -> ServerConfig:
    """Flare's default `ServerConfig` with `max_body_bytes` as the request body
    limit of both protocols: `max_body_size` (HTTP/1.1) and
    `h2.max_body_size` (HTTP/2, which the first does not reach), and
    `shutdown_grace_ms` in `shutdown_timeout_ms`, where `Server.serve` reads
    it (Flare's `drain` takes its window as an argument). Raises
    `max_body_bytes out of range: <value>` outside 0 to 2^59 - 1, then
    `shutdown_grace_ms out of range: <value>` outside 0 to 86,400,000."""
    if max_body_bytes < 0 or max_body_bytes > _LARGEST_MAX_BODY_BYTES:
        raise Error("max_body_bytes out of range: " + String(max_body_bytes))
    if shutdown_grace_ms < 0 or shutdown_grace_ms > _LARGEST_SHUTDOWN_GRACE_MS:
        raise Error(
            "shutdown_grace_ms out of range: " + String(shutdown_grace_ms)
        )
    var config = ServerConfig(max_body_size=max_body_bytes)
    config.h2.max_body_size = max_body_bytes
    config.shutdown_timeout_ms = shutdown_grace_ms
    return config^


struct Server(Movable):
    """A listening socket that serves a Muntin `App` over HTTP through Flare
    (M3-033). `Server.bind` is the one public spelling."""

    var _server: HttpServer

    def __init__(
        out self,
        *,
        _host: String,
        _port: Int,
        _max_body_bytes: Int = _DEFAULT_MAX_BODY_BYTES,
        _shutdown_grace_ms: Int = _DEFAULT_SHUTDOWN_GRACE_MS,
    ) raises:
        if _port < 0 or _port > 65535:
            raise Error("port out of range: " + String(_port))
        var config = _server_config(_max_body_bytes, _shutdown_grace_ms)
        self._server = HttpServer.bind(
            SocketAddr(IpAddr.parse(_host), UInt16(_port)), config^
        )

    @staticmethod
    def bind(
        host: String,
        port: Int,
        *,
        max_body_bytes: Int = _DEFAULT_MAX_BODY_BYTES,
        shutdown_grace_ms: Int = _DEFAULT_SHUTDOWN_GRACE_MS,
    ) raises -> Server:
        """Binds and listens on `host` (an IPv4 or IPv6 literal) and `port`
        (0 to 65535; 0 lets the system choose). A client may connect once it
        returns. `max_body_bytes` (0 to 2^59 - 1; 10 MiB when not given)
        bounds the request body Flare receives, over HTTP/1.1 and h2c: a
        longer one is refused while it arrives, before the adapter (M3-044).
        It does not promise to accept every body within it: over HTTP/1.1
        Flare refuses (413) when a request's head, chunk framing, body and
        any pipelined bytes buffered together exceed `max_body_bytes` plus
        8192. `shutdown_grace_ms` (0 to 86,400,000; 5000 when not given) is
        how long `serve` keeps serving the open connections after SIGTERM
        or SIGINT (M3-045; docs/DX.md section 1).
        Raises for a port, limit or grace out of range, a host that is not
        an IP literal, an address in use or any other OS error."""
        return Server(
            _host=host,
            _port=port,
            _max_body_bytes=max_body_bytes,
            _shutdown_grace_ms=shutdown_grace_ms,
        )

    def port(self) -> Int:
        """The bound port: the system's choice when bound with 0."""
        return Int(self._server.local_addr().port)

    def serve(mut self, app: App) raises:
        """Serves the borrowed `app` on the calling thread with Flare's
        single-worker reactor. It does not return while serving; when
        Flare's `serve` raises, the raise propagates, and when it returns,
        this returns. Raises `FLARE_BUFRING_HANDLER=1 is unsupported by
        Muntin with Flare v0.12.0`, before serving, when the environment
        sets `FLARE_BUFRING_HANDLER` to `1`, the value with which Flare's
        `serve` takes its buffer-ring loop on Linux with io_uring; it
        refuses it on every system (M3-044).

        SIGTERM and SIGINT stop it gracefully while it serves (M3-045;
        docs/DX.md section 1): new connections are refused at once, the
        open ones are served for `shutdown_grace_ms`, then Flare closes
        what is left and this returns. A second stop signal ends the
        process by the default action; a handler still running
        `_REACTOR_STOP_MS` after the window ends it with 128 + the signal.
        The dispositions both signals had are back when this returns or
        raises."""
        if getenv("FLARE_BUFRING_HANDLER") == "1":
            raise Error(_BUFRING_UNSUPPORTED)
        var watch = _StopWatch(
            Int(Pointer(to=self._server)),
            self._server.config.shutdown_timeout_ms,
        )
        try:
            self._server.serve(_BorrowedHandler(app))
        except e:
            # A stop that closed the listener before Flare's `serve` set up
            # its reactor makes that `serve` raise: still a stop.
            if watch.finish() == 0:
                raise e^
            return
        _ = watch.finish()
