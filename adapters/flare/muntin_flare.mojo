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
(Flare's `IpAddr.parse`: no name resolution), with Flare's default
`ServerConfig`. A bind failure raises; dropping the `Server` closes its
listener. `server.port()` is the bound port. `server.serve(app)` borrows
`app` and runs Flare's single-worker `serve` on the calling thread with
`_BorrowedHandler`, which answers through `_serve_app` as `MuntinHandler`
does; a raise propagates and a return returns, with no policy of its own.
On Flare v0.12.0 a return means the reactor stopped (a failed poll). There
is no stop call, graceful shutdown, signal handling, worker count or
backend configuration: SIGINT and SIGTERM end the process unless it
inherited them ignored (the Mojo 1.1.0 runtime's own handler re-raises
them).
`_BorrowedHandler` is not `Copyable`, which keeps Flare's multi-worker
`serve` out of reach. `Server`'s one initializer takes
keyword-only `_host` and `_port`, so `Server.bind` is the one public
spelling. `MuntinHandler` stays for the adapter's own tests and probes.
"""

from flare.http import (
    Handler,
    HttpServer,
    Request as FlareRequest,
    Response as FlareResponse,
)
from flare.net import IpAddr, SocketAddr
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


struct Server(Movable):
    """A listening socket that serves a Muntin `App` over HTTP through Flare
    (M3-033). `Server.bind` is the one public spelling."""

    var _server: HttpServer

    def __init__(out self, *, _host: String, _port: Int) raises:
        if _port < 0 or _port > 65535:
            raise Error("port out of range: " + String(_port))
        self._server = HttpServer.bind(
            SocketAddr(IpAddr.parse(_host), UInt16(_port))
        )

    @staticmethod
    def bind(host: String, port: Int) raises -> Server:
        """Binds and listens on `host` (an IPv4 or IPv6 literal) and `port`
        (0 to 65535; 0 lets the system choose). A client may connect once it
        returns. Raises for a port out of range, a host that is not an IP
        literal, an address in use or any other OS error."""
        return Server(_host=host, _port=port)

    def port(self) -> Int:
        """The bound port: the system's choice when bound with 0."""
        return Int(self._server.local_addr().port)

    def serve(mut self, app: App) raises:
        """Serves the borrowed `app` on the calling thread with Flare's
        single-worker reactor. It does not return while serving; when
        Flare's `serve` raises, the raise propagates, and when it returns,
        this returns."""
        self._server.serve(_BorrowedHandler(app))
