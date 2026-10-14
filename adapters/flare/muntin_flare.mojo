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
does; a raise propagates and a return returns, with one exception: a raise
after a stop signal (below) returns. It returns after a graceful stop or
when the reactor stopped on a failed poll. There is no stop call, worker count or backend configuration
other than the body limit, the grace window and the idle timeout below.
`_BorrowedHandler` is not `Copyable`, which keeps Flare's multi-worker
`serve` out of reach. `Server`'s one initializer takes keyword-only `_host`,
`_port`, `_max_body_bytes`, `_shutdown_grace_ms` and `_idle_timeout_ms`, so
`Server.bind` is the one public spelling.
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

Idle timeout (M3-047, decided in docs/history/architecture-decisions.md
"Server idle timeout decision (M3-047)"): `Server.bind`'s keyword-only
`idle_timeout_ms` (500, Flare v0.12.0's default, when not given) is written
into Flare's one `idle_timeout_ms`, which its HTTP/1.1 and HTTP/2 handles
both read: how long a connection stays open while nothing arrives on it.
`_server_config` checks it after the grace window and before the host is
parsed: 1 to 86,400,000 (`idle_timeout_ms out of range: <value>`
otherwise), since Flare reads 0 and negative values as no idle timer.

TLS (M3-051, decided in docs/history/architecture-decisions.md "Server TLS
decision (M3-051)"): `Server.bind`'s keyword-only `tls`, a `Tls` holding a
PEM certificate chain's and private key's paths, serves HTTPS instead of
cleartext through Flare's `HttpServer.bind_tls`, offering `h2` then
`http/1.1` (ALPN) and with the same `ServerConfig`, so the three settings
and the stop apply unchanged. `_check_tls_files` reads both files first
(regular files of at most 1 MiB) and raises naming the one that cannot be
read, holds no PEM certificate, or whose first PEM private key is encrypted
or missing; Flare's own load failure, which carries no reason, is raised
naming both files and no cause. Flare takes paths, so OpenSSL reads the
files again.

Graceful shutdown (M3-045, decided in docs/history/architecture-decisions.md
"Graceful shutdown decision (M3-045)"): while `serve` runs, SIGTERM and
SIGINT stop it. `_StopWatch` installs `_stop_signal_seen`, a handler that
does nothing, with `SA_RESETHAND`, so a delivered signal only resets its
disposition to `SIG_DFL`; a watcher thread (`_watch_for_stop`) sees that,
resets both to `SIG_DFL` (a second one takes the default action; if a
reset fails, it ends the process at once with 128 + the signal) and calls
Flare's `drain` with `Server.bind`'s `shutdown_grace_ms` (0 to
86,400,000; 5000 when not given, Flare v0.12.0's default, kept in
`ServerConfig.shutdown_timeout_ms`): the listener closes, the open
connections are served for the whole window, then Flare closes them and its
`serve` returns. A handler still running `_REACTOR_STOP_MS` after `drain`
returned ends the process with 128 + the signal. When `serve` returns or
raises, the watcher is joined and both dispositions are put back. The
dispositions are process-wide, so `_StopWatch` first claims the process's
one serving cell (`_get_global`) and another `serve` meanwhile raises
`Server.serve is already serving in this process`; every `sigaction`
result is checked. What clients see: docs/DX.md section 1.
"""

from std.atomic import Atomic, Ordering
from std.ffi import _get_global, c_int, external_call, get_errno
from std.io import FileDescriptor
from std.os import abort, getenv, stat
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
from flare.utils import exit
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

comptime _DEFAULT_IDLE_TIMEOUT_MS = 500
"""`Server.bind`'s idle timeout when none is given: Flare v0.12.0's
`ServerConfig.idle_timeout_ms` default, written here so that a Flare upgrade
does not change it (M3-047)."""

comptime _LARGEST_IDLE_TIMEOUT_MS = 86_400_000
"""One day, the largest idle timeout `Server.bind` takes (M3-047)."""

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
Linux x86-64 glibc, 16 on macOS arm64). The handler is its first word on
both."""
comptime _SA_FLAGS_OFFSET = 12 if CompilationTarget.is_macos() else 136
comptime _SA_RESTART_RESETHAND = (
    0x2 | 0x4 if CompilationTarget.is_macos() else 0x10000000 | 0x80000000
)
"""`SA_RESTART | SA_RESETHAND`: interrupted system calls restart, and the
kernel resets the disposition to `SIG_DFL` as it delivers the signal. These
values and `_SA_FLAGS_OFFSET` are verified on Linux x86-64 (glibc) and macOS
arm64 only, the project's two platforms; `_StopWatch` refuses to compile
elsewhere."""

comptime _ALREADY_SERVING = "Server.serve is already serving in this process"
"""What `Server.serve` raises, before touching any signal, while another
`serve` runs in the same process: SIGTERM and SIGINT dispositions are
process-wide, so one `serve` at a time owns them (M3-045)."""

comptime _STAGE_INSTALLED = 1
"""`serve`'s `_stage` hook: both stop handlers are installed and the watcher
is not yet started."""
comptime _STAGE_WATCHING = 2
"""`_stage`: the watcher is running and Flare's `serve` is not yet called."""
comptime _STAGE_SERVED = 3
"""`_stage`: Flare's `serve` returned or raised; the watcher still runs."""
comptime _STAGE_JOINED = 4
"""`_stage`: the watcher is joined; the dispositions are not yet restored."""
comptime _STAGE_RESTORED = 5
"""`_stage`: the dispositions are restored and a stop signal the watcher did
not act on is sent again; the serving claim is not yet released."""

comptime _CB_DONE = 0
"""Control block cell: 1 once Flare's `serve` has returned or raised."""
comptime _CB_SERVER = 1
"""Control block cell: the address of the serving `HttpServer`."""
comptime _CB_GRACE = 2
"""Control block cell: the grace window, in milliseconds."""
comptime _CB_SIGNAL = 3
"""Control block cell: the stop signal the watcher acted on, or 0."""
comptime _CB_DRAIN_ERROR = 4
"""Control block cell: the address of the `String` the watcher writes
Flare's `drain` error into; set to 1 in `_CB_DRAIN_FAILED` after it."""
comptime _CB_DRAIN_FAILED = 5
"""Control block cell: 1 when Flare's `drain` raised and the watcher fell
back to `close` (a hard stop)."""
comptime _CB_LEN = 6


def _no_stage(stage: Int):
    """`Server.serve`'s default `_stage` hook: nothing."""
    pass


def _stop_signal_seen(sig: c_int) abi("C"):
    """The handler `Server.serve` installs for SIGTERM and SIGINT. It does
    nothing: with `SA_RESETHAND` the kernel resets the disposition to
    `SIG_DFL` as it delivers the signal, and that reset is the notification
    the watcher reads. No allocation, lock, raise, global or Flare or Mojo
    object is touched in signal context (M3-045)."""
    pass


def _sigaction(sig: Int, new: Int, old: Int) -> Int:
    """`sigaction(2)` with both `struct sigaction` pointers as addresses (0 is
    NULL): 0, or -1 with `errno` set."""
    return Int(external_call["sigaction", c_int](c_int(sig), new, old))


def _send_here(sig: Int):
    """Sends `sig` again to the calling thread (`raise(3)`), so its
    disposition is acted on before this returns: a terminating default
    action ends the process, a handler runs on this thread. `kill` to the
    process could run a handler on another thread later, after the serving
    claim is released. If the calling thread blocks `sig`, it stays pending
    on that thread past the release and is acted on, once unblocked, by the
    disposition current then (a later `serve`'s stop handler included):
    `serve` is supported only on a thread that blocks neither SIGTERM nor
    SIGINT (docs/DX.md section 1; M3-045)."""
    _ = external_call["raise", c_int](c_int(sig))


def _errno() -> String:
    return "errno " + String(Int(get_errno().value))


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


def _new_serving_cell() -> Optional[Pointer[NoneType, MutUntrackedOrigin]]:
    var cell = Int(external_call["calloc", Int](1, 8))
    if cell == 0:
        return None
    return Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=cell)


def _free_serving_cell(cell: Optional[Pointer[NoneType, MutUntrackedOrigin]]):
    if cell:
        external_call["free", NoneType](Int(cell.value()))


def _serving_cell() -> Int:
    """The address of the process's one serving cell: 1 while a `serve` owns
    the stop signals, else 0. Mojo 1.1.0 has no module-level `var`; the
    standard library's `_get_global` creates the cell once per process,
    under its own lock (M3-045)."""
    var cell = _get_global[
        "muntin_flare.serving", _new_serving_cell, _free_serving_cell
    ]()
    if not cell:
        abort("Server.serve: no memory for the process's serving cell")
    return Int(cell.value())


def _claim_serving() -> Bool:
    """Sets the serving cell from 0 to 1 atomically; `False` if another
    `serve` holds it."""
    var expected = Int64(0)
    return Atomic[Int64].compare_exchange(
        _cell(_serving_cell(), 0), expected, Int64(1)
    )


def _release_serving():
    _store(_serving_cell(), 0, 0)


def _serving_held() -> Bool:
    """Whether a `serve` holds the process's serving claim (for tests)."""
    return _load(_serving_cell(), 0) != 0


def _watch_for_stop(arg: _OpaquePtr) -> _OpaquePtr:
    """The watcher thread `Server.serve` runs beside Flare's reactor (M3-045).

    Every `_WATCH_POLL_MS` it reads the dispositions of SIGTERM and SIGINT;
    one that is back to `SIG_DFL` was delivered (a read that fails is not a
    delivery: it reads again next turn). It then resets both to `SIG_DFL`,
    so a second stop signal ends the process by the default action; if
    either reset fails, a second signal could be absorbed by the stop
    handler, so it ends the process at once with status 128 + the
    signal, without a graceful stop. Otherwise it calls Flare's `drain`
    with the grace window, which closes the listener, keeps the reactor
    serving the open connections for the whole window and then sets its
    stop flag. If `drain` raises, it writes the error where
    `_CB_DRAIN_ERROR` points, marks `_CB_DRAIN_FAILED` and falls back to
    `close`, Flare's hard stop; `serve` then raises. If the reactor has not
    left its loop `_REACTOR_STOP_MS` after `drain` returned (a handler still
    running), it ends the process with status 128 + the signal. It returns
    when the serving thread marks `_CB_DONE`. Never raises (a pthread start
    routine)."""
    var block = Int(arg)
    var seen = List[UInt8](length=_SIGACTION_BYTES, fill=0)
    var sig = 0
    while sig == 0:
        if _load(block, _CB_DONE) != 0:
            return arg
        for candidate in [_SIGTERM, _SIGINT]:
            if (
                sig == 0
                and _sigaction(candidate, 0, Int(seen.unsafe_ptr())) == 0
                and seen.unsafe_ptr().unsafe_bitcast[Int]()[] == 0
            ):
                sig = candidate
        if sig == 0:
            _ = libc_nanosleep_ms(_WATCH_POLL_MS)
    _store(block, _CB_SIGNAL, sig)
    var default = List[UInt8](length=_SIGACTION_BYTES, fill=0)
    if (
        _sigaction(_SIGTERM, Int(default.unsafe_ptr()), 0) != 0
        or _sigaction(_SIGINT, Int(default.unsafe_ptr()), 0) != 0
    ):
        # The second-signal escape cannot be kept: stop now instead.
        exit(128 + sig)
    var server = Pointer[HttpServer, MutUntrackedOrigin](
        unsafe_from_address=_load(block, _CB_SERVER)
    )
    try:
        _ = server[].drain(_load(block, _CB_GRACE))
    except e:
        Pointer[String, MutUntrackedOrigin](
            unsafe_from_address=_load(block, _CB_DRAIN_ERROR)
        )[] = String(e)
        _store(block, _CB_DRAIN_FAILED, 1)
        server[].close()
    var deadline = monotonic_now_ms() + _REACTOR_STOP_MS
    while _load(block, _CB_DONE) == 0:
        if monotonic_now_ms() >= deadline:
            exit(128 + sig)
        _ = libc_nanosleep_ms(5)
    _ = seen^
    _ = default^
    return arg


def _restore_one(sig: Int, saved: Int, mut failure: String) -> Int:
    """Puts back `sig`'s disposition saved at `saved`, reading the one it
    replaces in the same call: -1 if `sigaction` failed (`failure` then
    names the call and its `errno`), 1 if the replaced disposition was
    `SIG_DFL` (`sig` was delivered since it was last set), else 0."""
    var replaced = List[UInt8](length=_SIGACTION_BYTES, fill=0)
    if _sigaction(sig, saved, Int(replaced.unsafe_ptr())) != 0:
        failure = "sigaction(" + String(sig) + "): " + _errno()
        return -1
    var delivered = replaced.unsafe_ptr().unsafe_bitcast[Int]()[] == 0
    _ = replaced^
    return 1 if delivered else 0


def _restore_both(previous: Int, mut failure: String) -> Int:
    """Puts back the SIGTERM and SIGINT dispositions saved at `previous` (two
    `struct sigaction` slots). Returns a signal delivered since the stop
    handler was installed (its replaced disposition was `SIG_DFL`) among
    those put back, or 0; `failure` is left empty, or names a `sigaction`
    that failed (that signal may keep the stop handler)."""
    var term = _restore_one(_SIGTERM, previous, failure)
    var int = _restore_one(_SIGINT, previous + _SIGACTION_BYTES, failure)
    if term == 1:
        return _SIGTERM
    if int == 1:
        return _SIGINT
    return 0


struct _StopWatch(Movable):
    """What `Server.serve` sets up around Flare's `serve` and undoes after it
    (M3-045): the process's serving claim, the stop handler on SIGTERM and
    SIGINT, the dispositions it replaced, and the watcher thread with its
    control block. The block, the error string and the server it points to
    outlive the thread, which `finish` joins before anything is freed."""

    var _block: List[Int64]
    var _previous: List[UInt8]
    var _drain_error: List[String]
    var _watcher: ThreadHandle

    def __init__(
        out self,
        server_addr: Int,
        grace_ms: Int,
        stage: def(Int) thin -> None,
    ) raises:
        """Claims the process's serving cell (raises `_ALREADY_SERVING`
        otherwise), installs the stop handler on SIGTERM then SIGINT and
        starts the watcher. If an install or the start fails, what was
        changed is put back, the claim is released and it raises, before
        any serving."""
        comptime assert (
            CompilationTarget.is_linux() and CompilationTarget.is_x86()
        ) or (
            # macOS is arm64 or x86-64: not x86 is arm64.
            CompilationTarget.is_macos()
            and not CompilationTarget.is_x86()
        ), (
            "muntin_flare: Server's stop handling writes struct sigaction's"
            " layout and flags for Linux x86-64 and macOS arm64 only, where"
            " they were verified (M3-045)"
        )
        if not _claim_serving():
            raise Error(_ALREADY_SERVING)
        self._block = List[Int64](length=_CB_LEN, fill=0)
        self._drain_error = List[String](length=1, fill=String())
        var block = Int(self._block.unsafe_ptr())
        _store(block, _CB_SERVER, server_addr)
        _store(block, _CB_GRACE, grace_ms)
        _store(block, _CB_DRAIN_ERROR, Int(self._drain_error.unsafe_ptr()))
        var handler: def(c_int) thin abi("C") -> None = _stop_signal_seen
        var action = List[UInt8](length=_SIGACTION_BYTES, fill=0)
        var at = action.unsafe_ptr()
        at.unsafe_bitcast[Int]()[] = Pointer(to=handler).unsafe_bitcast[Int]()[]
        at.unsafe_offset(_SA_FLAGS_OFFSET).unsafe_bitcast[Int32]()[] = Int32(
            _SA_RESTART_RESETHAND
        )
        self._previous = List[UInt8](length=2 * _SIGACTION_BYTES, fill=0)
        var previous = Int(self._previous.unsafe_ptr())
        if _sigaction(_SIGTERM, Int(at), previous) != 0:
            var failure = _errno()
            _release_serving()
            raise Error("serve: sigaction(SIGTERM) failed: " + failure)
        if _sigaction(_SIGINT, Int(at), previous + _SIGACTION_BYTES) != 0:
            var failure = _errno()
            var undo = String()
            var delivered = _restore_one(_SIGTERM, previous, undo)
            if undo:
                # SIGTERM may keep the stop handler: hold the claim, so no
                # later `serve` saves it as the disposition to put back.
                raise Error(
                    "serve: sigaction(SIGINT) failed: "
                    + failure
                    + "; putting SIGTERM back failed too: "
                    + undo
                )
            if delivered == 1:
                _send_here(_SIGTERM)
            _release_serving()
            raise Error("serve: sigaction(SIGINT) failed: " + failure)
        _ = action^
        stage(_STAGE_INSTALLED)
        try:
            self._watcher = ThreadHandle.spawn_os[_watch_for_stop](
                _OpaquePtr(unsafe_from_address=block)
            )
        except e:
            var undo = String()
            var resend = _restore_both(previous, undo)
            if resend > 0:
                _send_here(resend)
            if not undo:
                _release_serving()
            if undo:
                raise Error(
                    String(e)
                    + "; putting the dispositions back failed: "
                    + undo
                )
            raise e^

    def finish(mut self, stage: def(Int) thin -> None) raises -> Int:
        """Marks serving done, joins the watcher, puts the dispositions
        `__init__` replaced back and releases the serving claim. Returns the
        stop signal the watcher acted on, or 0.

        A stop signal the watcher did not act on (it arrived as serving
        ended for another reason) is sent again once the previous
        dispositions are back, so it is not lost: the restore reads what it
        replaces in the same `sigaction` call. It is sent to this thread
        and acted on before the claim is released, so no later `serve` has
        installed its handler by then. If the watcher cannot be
        joined, it may still read this block, so after putting the
        dispositions back the process aborts rather than free it. Raises
        when a restore failed (the claim then stays held: a signal may keep
        the stop handler, and no later `serve` may save it as the
        disposition to put back), or when Flare's `drain` raised (the stop
        was then a hard stop, not a graceful one)."""
        var block = Int(self._block.unsafe_ptr())
        stage(_STAGE_SERVED)
        _store(block, _CB_DONE, 1)
        try:
            self._watcher.join()
        except e:
            var ignored = String()
            _ = _restore_both(Int(self._previous.unsafe_ptr()), ignored)
            abort(
                "Server.serve: the stop watcher could not be joined ("
                + String(e)
                + ")"
            )
        stage(_STAGE_JOINED)
        var acted = _load(block, _CB_SIGNAL)
        var failure = String()
        var delivered = _restore_both(Int(self._previous.unsafe_ptr()), failure)
        if acted == 0 and delivered > 0:
            _send_here(delivered)
        stage(_STAGE_RESTORED)
        if not failure:
            _release_serving()
        if failure:
            # A signal may keep the stop handler with no watcher behind it:
            # the claim stays held, so no later `serve` in this process
            # saves that handler as the disposition to put back.
            raise Error(
                "serve: putting back the SIGTERM and SIGINT dispositions"
                " failed ("
                + failure
                + "); this process cannot serve again"
            )
        if _load(block, _CB_DRAIN_FAILED) != 0:
            raise Error(
                "serve: the graceful stop failed and open connections were"
                " closed at once: Flare's drain raised: "
                + self._drain_error[0]
            )
        return acted


def _server_config(
    max_body_bytes: Int,
    shutdown_grace_ms: Int = _DEFAULT_SHUTDOWN_GRACE_MS,
    idle_timeout_ms: Int = _DEFAULT_IDLE_TIMEOUT_MS,
) raises -> ServerConfig:
    """Flare's default `ServerConfig` with `max_body_bytes` as the request body
    limit of both protocols: `max_body_size` (HTTP/1.1) and
    `h2.max_body_size` (HTTP/2, which the first does not reach),
    `shutdown_grace_ms` in `shutdown_timeout_ms`, where `Server.serve` reads
    it (Flare's `drain` takes its window as an argument), and
    `idle_timeout_ms` in Flare's one field of that name, which both
    protocols read. Raises `max_body_bytes out of range: <value>` outside 0
    to 2^59 - 1, then `shutdown_grace_ms out of range: <value>` outside 0 to
    86,400,000, then `idle_timeout_ms out of range: <value>` outside 1 to
    86,400,000 (Flare reads 0, and a negative value, as no idle timer)."""
    if max_body_bytes < 0 or max_body_bytes > _LARGEST_MAX_BODY_BYTES:
        raise Error("max_body_bytes out of range: " + String(max_body_bytes))
    if shutdown_grace_ms < 0 or shutdown_grace_ms > _LARGEST_SHUTDOWN_GRACE_MS:
        raise Error(
            "shutdown_grace_ms out of range: " + String(shutdown_grace_ms)
        )
    if idle_timeout_ms < 1 or idle_timeout_ms > _LARGEST_IDLE_TIMEOUT_MS:
        raise Error("idle_timeout_ms out of range: " + String(idle_timeout_ms))
    var config = ServerConfig(max_body_size=max_body_bytes)
    config.h2.max_body_size = max_body_bytes
    config.shutdown_timeout_ms = shutdown_grace_ms
    config.idle_timeout_ms = idle_timeout_ms
    return config^


comptime _PEM_CERTIFICATE = "-----BEGIN CERTIFICATE-----"
comptime _FLARE_TLS_LOAD_FAILED = "flare_ssl_ctx_new_server failed"
comptime _TLS_FILE_MAX_BYTES = 1_048_576
"""The largest certificate or key file `Server.bind` reads: far above a
certificate chain's few kilobytes, small enough that a wrong path fails fast."""


struct Tls(Copyable, Movable):
    """The certificate chain and private key a `Server` serves HTTPS with
    (M3-051): paths to PEM files, which `Server.bind` checks and OpenSSL then
    loads. Both are required and named, so neither can be left out or
    swapped by position."""

    var cert_file: String
    """The server certificate, then any intermediates, in PEM."""
    var key_file: String
    """The certificate's private key in PEM, not encrypted."""

    def __init__(out self, *, cert_file: String, key_file: String):
        self.cert_file = cert_file
        self.key_file = key_file


def _open_flags() -> c_int:
    """`O_RDONLY | O_NONBLOCK | O_CLOEXEC`: opening a FIFO with no writer
    returns at once instead of waiting for one."""
    comptime if CompilationTarget.is_macos():
        return c_int(0x4 | 0x1000000)
    else:
        return c_int(0o4000 | 0o2000000)


def _at_fdcwd() -> c_int:
    """`AT_FDCWD`. `openat` is called rather than `open`, whose name the
    standard library declares with another signature in the same program."""
    comptime if CompilationTarget.is_macos():
        return c_int(-2)
    else:
        return c_int(-100)


def _read_tls_file(what: String, path: String) raises -> List[UInt8]:
    """The file's bytes, if it is a regular file (a symbolic link to one
    included) of at most `_TLS_FILE_MAX_BYTES`. The path is opened once,
    without blocking, and the opened file itself is checked and read
    (through `/dev/fd/<fd>`), so a device or a FIFO, even one put in its
    place after any earlier look, cannot block or exhaust `Server.bind`."""
    var prefix = "TLS " + what + " file "
    var c_path = path.copy()
    var fd = Int(
        external_call["openat", c_int](
            _at_fdcwd(), Int(c_path.as_c_string_span().ptr()), _open_flags()
        )
    )
    _ = c_path^
    if fd < 0:
        raise Error(
            prefix
            + "cannot be read: "
            + path
            + " ("
            + String(get_errno())
            + ")"
        )
    try:
        var st = stat("/dev/fd/" + String(fd))
        if (Int(st.st_mode) & 0o170000) != 0o100000:
            raise Error(prefix + "is not a regular file: " + path)
        var data = List[UInt8](length=_TLS_FILE_MAX_BYTES + 1, fill=0)
        var got = 0
        var file = FileDescriptor(fd)
        while got <= _TLS_FILE_MAX_BYTES:
            var n: Int
            try:
                n = file.read_bytes(Span(data)[got:])
            except e:
                raise Error(
                    prefix + "cannot be read: " + path + " (" + String(e) + ")"
                )
            if n == 0:
                break
            got += n
        if got > _TLS_FILE_MAX_BYTES:
            raise Error(
                prefix
                + "is larger than "
                + String(_TLS_FILE_MAX_BYTES)
                + " bytes: "
                + path
            )
        data.shrink(got)
        return data^
    finally:
        _ = external_call["close", c_int](c_int(fd))


@fieldwise_init
struct _PemBegin(Copyable, Movable):
    var label: String
    """What a `-----BEGIN <label>-----` line names."""
    var encrypted_header: Bool
    """Whether the next line is the older form's `Proc-Type: 4,ENCRYPTED`."""


def _pem_begins(data: List[UInt8]) -> List[_PemBegin]:
    """Every PEM block's BEGIN line, in order. As OpenSSL's PEM reader, only
    a line that starts with `-----BEGIN ` begins a block; any other text,
    a comment naming a block included, is not one."""
    var lines = String(from_utf8_lossy=Span(data)).split("\n")
    var out = List[_PemBegin]()
    for i in range(len(lines)):
        var line = String(lines[i]).removesuffix("\r")
        if not (line.startswith("-----BEGIN ") and line.endswith("-----")):
            continue
        var label = String(line[byte = 11 : line.byte_length() - 5])
        var encrypted = i + 1 < len(lines) and String(lines[i + 1]).startswith(
            "Proc-Type: 4,ENCRYPTED"
        )
        out.append(_PemBegin(label, encrypted))
    return out^


def _check_tls_files(tls: Tls) raises:
    """Raises, naming the file, when a file cannot be read, when the
    certificate file holds no PEM certificate block, or when the key file's
    first PEM private key block (the one OpenSSL loads) is encrypted (OpenSSL
    would ask for its passphrase on the terminal) or there is none. What only
    OpenSSL can tell (a damaged PEM block, a key that does not belong to the
    certificate) is `Server`'s check after Flare's. OpenSSL opens the paths
    again, so a file replaced in between is loaded unchecked (M3-051)."""
    var cert = _read_tls_file("certificate", tls.cert_file)
    var key = _read_tls_file("key", tls.key_file)
    var has_cert = False
    for b in _pem_begins(cert):
        if b.label == "CERTIFICATE":
            has_cert = True
    if not has_cert:
        raise Error(
            "TLS certificate file has no PEM certificate ("
            + _PEM_CERTIFICATE
            + "): "
            + tls.cert_file
        )
    for b in _pem_begins(key):
        if b.label == "ENCRYPTED PRIVATE KEY" or (
            b.label.endswith("PRIVATE KEY") and b.encrypted_header
        ):
            raise Error(
                "TLS key file holds an encrypted private key, which is not"
                " supported: "
                + tls.key_file
            )
        if (
            b.label == "PRIVATE KEY"
            or b.label == "RSA PRIVATE KEY"
            or b.label == "EC PRIVATE KEY"
        ):
            return
    raise Error("TLS key file has no PEM private key: " + tls.key_file)


def _tls_alpn() -> List[String]:
    """The protocols a TLS `Server` offers in the handshake, in preference
    order: the ones its cleartext listener serves (M3-051)."""
    var alpn = List[String]()
    alpn.append("h2")
    alpn.append("http/1.1")
    return alpn^


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
        _idle_timeout_ms: Int = _DEFAULT_IDLE_TIMEOUT_MS,
        _tls: Optional[Tls] = None,
    ) raises:
        if _port < 0 or _port > 65535:
            raise Error("port out of range: " + String(_port))
        var config = _server_config(
            _max_body_bytes, _shutdown_grace_ms, _idle_timeout_ms
        )
        if not _tls:
            self._server = HttpServer.bind(
                SocketAddr(IpAddr.parse(_host), UInt16(_port)), config^
            )
            return
        ref tls = _tls.value()
        var addr = SocketAddr(IpAddr.parse(_host), UInt16(_port))
        _check_tls_files(tls)
        try:
            self._server = HttpServer.bind_tls(
                addr, tls.cert_file, tls.key_file, _tls_alpn(), config^
            )
        except e:
            if String(e).startswith(_FLARE_TLS_LOAD_FAILED):
                raise Error(
                    "TLS certificate or private key could not be loaded: "
                    + tls.cert_file
                    + ", "
                    + tls.key_file
                )
            raise e^

    @staticmethod
    def bind(
        host: String,
        port: Int,
        *,
        max_body_bytes: Int = _DEFAULT_MAX_BODY_BYTES,
        shutdown_grace_ms: Int = _DEFAULT_SHUTDOWN_GRACE_MS,
        idle_timeout_ms: Int = _DEFAULT_IDLE_TIMEOUT_MS,
        tls: Optional[Tls] = None,
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
        or SIGINT (M3-045; docs/DX.md section 1). `idle_timeout_ms` (1 to
        86,400,000; 500 when not given) is how long Flare keeps a
        connection open, over HTTP/1.1 and h2c, while nothing arrives on it
        (M3-047; docs/DX.md section 1). With `tls`, it serves HTTPS
        instead, HTTP/1.1 and HTTP/2 chosen in the TLS handshake (ALPN), with
        the same three settings (M3-051; docs/DX.md section 1); the files are
        read and checked here, after the host is parsed.
        Raises for a port, limit, grace or idle timeout out of range, a TLS
        file that cannot be read or loaded (naming it), a host that is not
        an IP literal, an address in use or any other OS error."""
        return Server(
            _host=host,
            _port=port,
            _max_body_bytes=max_body_bytes,
            _shutdown_grace_ms=shutdown_grace_ms,
            _idle_timeout_ms=idle_timeout_ms,
            _tls=tls,
        )

    def port(self) -> Int:
        """The bound port: the system's choice when bound with 0."""
        return Int(self._server.local_addr().port)

    def serve(
        mut self,
        app: App,
        *,
        _stage: def(Int) thin -> None = _no_stage,
    ) raises:
        """Serves the borrowed `app` on the calling thread with Flare's
        single-worker reactor. It does not return while serving; when
        Flare's `serve` raises, the raise propagates (unless a stop signal
        was acted on: a stop that closed the listener before Flare's reactor
        was set up makes it raise, and this then returns), and when it
        returns, this returns. Raises `FLARE_BUFRING_HANDLER=1 is unsupported by
        Muntin with Flare v0.12.0`, before serving, when the environment
        sets `FLARE_BUFRING_HANDLER` to `1`, the value with which Flare's
        `serve` takes its buffer-ring loop on Linux with io_uring; it
        refuses it on every system (M3-044). Raises `Server.serve is
        already serving in this process`, before touching any signal, while
        another `serve` runs in the same process (M3-045).

        SIGTERM and SIGINT stop it gracefully while it serves (M3-045;
        docs/DX.md section 1): new connections are refused at once, the
        open ones are served for `shutdown_grace_ms`, then Flare closes
        what is left and this returns. A second stop signal ends the
        process by the default action (if resetting the dispositions to
        `SIG_DFL` for that fails, the stop is not graceful: the process
        ends at once with 128 + the signal); a handler still running
        `_REACTOR_STOP_MS` after Flare's `drain` returned ends it with
        128 + the signal. The dispositions both signals had are back when
        this returns or raises. If Flare's `drain` raises, the stop falls
        back to a hard stop and this raises with its error. The calling
        thread must block neither SIGTERM nor SIGINT, before or during this
        call: a stop signal sent again as it ends would otherwise stay
        pending on that thread after the claim is released.

        `_stage` is not API: the stop tests pass a hook called at the
        `_STAGE_*` points to place a signal there."""
        if getenv("FLARE_BUFRING_HANDLER") == "1":
            raise Error(_BUFRING_UNSUPPORTED)
        var watch = _StopWatch(
            Int(Pointer(to=self._server)),
            self._server.config.shutdown_timeout_ms,
            _stage,
        )
        _stage(_STAGE_WATCHING)
        try:
            self._server.serve(_BorrowedHandler(app))
        except e:
            # A stop that closed the listener before Flare's `serve` set up
            # its reactor makes that `serve` raise: still a stop.
            var acted: Int
            try:
                acted = watch.finish(_stage)
            except cleanup:
                raise Error(
                    String(cleanup)
                    + " (after Flare's serve raised: "
                    + String(e)
                    + ")"
                )
            if acted == 0:
                raise e^
            return
        _ = watch.finish(_stage)
