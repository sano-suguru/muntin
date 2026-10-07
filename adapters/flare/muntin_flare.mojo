"""Flare transport adapter for Muntin (M1-002). Not part of Muntin core.

Depends inward on Muntin's backend seam, `App.handle(Request) -> Response`,
and never routes on its own. Builds only in the `flare` pixi environment.

Conversion policy (M1; target handling restated for M2-002; headers M3-005,
decided in docs/history/architecture-decisions.md "Headers decision (M3-002)"):
- method: copied verbatim.
- request target: Flare's `url` (path plus any query, undecoded) passed
  verbatim to Muntin's `Request`, which splits path from query, exactly as
  for the in-memory backend. The adapter does not split, parse or decode the
  query, and does not use Flare's query helpers.
- request body: bytes copied into a `String`, decoded as UTF-8 with invalid
  sequences replaced by U+FFFD (Flare's `Request.text()`).
- request headers: every field, in order and casing, rebuilt from Flare's
  public `HeaderMap.encode_to` (Flare has no public field iterator) and
  verified against Flare's by-name view: the parsed count is `len()`, and
  per name the parsed values equal `get_all(name)` position by position.
  Over HTTP/1.1 the parse is exact; over cleartext HTTP/2 Flare admits a
  name with `:` inside, which a first-colon parse would misread as another
  field. A field that fails the check or `Headers.add` (a control byte, a
  non-token name) cannot be represented: the answer is 400.
- version and peer: dropped.
- response: status, body bytes and header fields copied; reason left unset,
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
  whose method is `HEAD`, `MuntinHandler.serve` takes the response it would
  send at every exit (`App.handle`'s answer, `to_flare_response`'s fixed
  500, its own 400) and sends its status and fields with no body, declaring
  a `Content-Length` equal to the body's byte length, except for a status
  that never carries content (1xx, 204, 205, 304), where it declares none.
  Flare v0.11.0 would send the content over cleartext HTTP/2, and over
  HTTP/1.1 frames an empty body as `Content-Length: 0`, so both steps are
  the adapter's; over HTTP/1.1 Flare still frames a 205 or 304 with
  `Content-Length: 0` itself. A handler's own `Content-Length` is still
  dropped. Every other method is unchanged.
"""

from flare.http import (
    Handler,
    Request as FlareRequest,
    Response as FlareResponse,
)
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
    return Request(
        request.method, request.url, request.text(), to_muntin_headers(request)
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
    var out = FlareResponse(
        status=response.status, body=List(response.body.as_bytes())
    )
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


struct MuntinHandler(Handler):
    """Serves a Muntin `App` as a Flare handler."""

    var app: App

    def __init__(out self, var app: App):
        self.app = app^

    def serve(self, request: FlareRequest) -> FlareResponse:
        if request.method == "HEAD":
            return _without_content(self._answer(request))
        return self._answer(request)

    def _answer(self, request: FlareRequest) -> FlareResponse:
        var muntin_request: Request
        try:
            muntin_request = to_muntin_request(request)
        except:
            return FlareResponse(
                status=400, body=List(String("Bad Request").as_bytes())
            )
        return to_flare_response(self.app.handle(muntin_request))
