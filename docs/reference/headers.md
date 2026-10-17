# Headers

## `Headers`

`muntin.Headers` is header fields in order.

- Each field keeps its name's casing; a repeated name (`Set-Cookie`) is several fields; an empty value is a value.
- `get(name)` returns the first value as `Optional[String]` (an absent field and an empty value differ), `get_all(name)` every value in order; `len`, `name(i)` and `value(i)` walk them. Names compare ASCII case-insensitively. `get` and `get_all` scan every field.
- `add(name, value)` appends; `set(name, value)` removes every field with that name, then appends. Both raise on a name that is not an RFC 9110 token, or on a value with a control byte (other than HTAB) or SP/HTAB at either end. In a raising handler that error is the fixed 500 (or its `ToErrorResponse`); code that must not raise, such as `to_response`, wraps `add` in `try`.
- Copies are explicit (`.copy()`).
- `Request.headers` holds what the backend received; `Request(method, target, body, headers^)` builds a request with fields. `Response.headers` starts empty.
- Known gap: `headers._fields` is reachable by name (Mojo 1.1.0 has no private fields) and bypasses `add`. The Flare adapter re-checks every outgoing field, and a route that rebuilds request fields answers such a field with the fixed 500.

## Reading fields in a handler

- A raw handler reads `req.headers` and sets fields on its `Response` ([raw handlers](raw.md)).
- A typed `post`, `put` or `patch` handler with a body reads them through `WithHeaders[B]` ([bodies](bodies.md#header-fields-with-a-body-withheadersb)).
- A typed `get` or `delete` handler, or a bodyless `post`, `put` or `patch` handler, takes `Headers` as its last parameter:

```mojo
from muntin import App, Headers, Response, State, ToErrorResponse


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(deinit self) -> Response:
        return Response.text("Unauthorized", status=401)


def me(headers: Headers) raises Unauthorized -> String:
    var token = headers.get("authorization")  # Optional[String]
    if not token:
        raise Unauthorized()  # ToErrorResponse: 401
    return "me " + token.value()


def note(id: Int, headers: Headers) -> String:  # route value, then the fields
    var traces = headers.get_all("x-trace")  # every value, in order
    return String(id, " traces=", len(traces))


def private_note(
    users: State[Users], id: Int, headers: Headers
) raises Unauthorized -> String:  # State first, as always
    var token = headers.get("authorization")
    if not token or not users[].allows(token.value()):    # a read-only Users method
        raise Unauthorized()
    return String("private ", id)


app.get["/me"](me)
app.get["/notes/{id}"](note)
app.get["/private/{id}"](private_note, users)
# GET /me  Authorization: t1             -> 200 "me t1"
# GET /me  (no Authorization)            -> 401 "Unauthorized" (the handler's error type)
# GET /notes/3  X-Trace: a  x-trace: b   -> 200 "3 traces=2"
# GET /notes/x                           -> 400 "Bad Request"  (note not called)
# GET /private/3  Authorization: <allowed token> -> 200 "private 3"; otherwise 401
```

- The parameter is a fresh value rebuilt for the handler, borrowed or owned (`var headers`); changing it changes no `Request`. `mut headers` matches no overload.
- **Muntin gives the fields no meaning**: a missing field is `None`, and the handler answers through its error type. There is no new 400, 413 or 415.
- `Headers` is the last parameter, once: `def(Headers, Int)` or two `Headers` is `constraint failed: a get handler takes one Headers, as its last parameter`. Beside a body it keeps the body messages (`def(Headers, B)`: `a post handler's parameter before the body is a route value: ...`).
- A typed function value spells it `var Headers`.
- Cost: the route copies each field name and value twice per request and validates each field again.

## Through the Flare adapter

- A request field Muntin cannot represent is answered 400 before `App.handle`, middleware included: over HTTP/2 Flare admits a name that is not a token, a control byte in a value and a value that is not UTF-8. Over HTTP/1.1 Flare answers a header byte ≥ 0x80 with 400 itself.
- A request without a `Host` field is answered 400 before middleware: over HTTP/1.1 (RFC 9112), and, by Muntin's policy, over HTTP/2 when it has no `:authority` either, a request upgraded with `Upgrade: h2c` included (Flare answers `101` first). `Host` in any casing counts, an empty value included; HTTP/1.0 needs none; the value is not checked ([M3-073](../history/architecture-decisions.md#request-host-decision-m3-073)).
- A request with more fields than the `Server`'s `max_header_fields` is answered 431 ([serving](serving.md#request-header-field-limit)).
- Over HTTP/2 a request's fields arrive in order as sent, names lowercase; Flare hands `:authority` over as a first `Host` field (dropping a `host` field) and joins the `cookie` fields with `; ` into one last `cookie` field.
- On the way out, fields the backend owns or that are connection-specific (`Content-Length`, `Transfer-Encoding`, `Connection`, `Keep-Alive`, `Proxy-Connection`, `Upgrade`, `TE`, `Trailer`) and any field a `Connection` value names are not written to the wire; they stay in the in-memory `Response`. Over HTTP/2 names go out lowercase. A field that fails the re-check is the adapter's 500.
- **A field middleware writes is not an authenticated identity**: request fields are client input (a client can send the same name), so an application must not hand an identity to a handler in a field.
