# Raw handlers and binary bodies

A raw handler takes the whole `Request` and returns a `Response`, for what typed shapes do not cover: webhooks, custom content types, unusual authentication, protocol integrations. Each example below is its own `App`; the line after it names the test that runs it and what that test adds or changes.

```mojo
from muntin import App, Request, Response


def webhook(req: Request) -> Response:       # `var req: Request` also works
    if Span(req.body) != "signed".as_bytes():  # application code decides
        return Response.text("unsigned", status=401)
    return Response.text("ok")


var app = App()
app.post["/webhook"](webhook)                # same syntax as typed handlers; app.get too
# POST /webhook          "signed"  -> 200 "ok"
# POST /webhook?id=abc   "forged"  -> 401 "unsigned"   (no 400 from Muntin: nothing is extracted)
# GET /webhook                    -> 405 "Method Not Allowed", Allow: POST  (webhook not called)
# POST /webhook/x                 -> 404 "Not Found"  (webhook not called)
```

Run by `tests/test_raw.mojo` (`test_dx_section_9_example`), with `webhook` as written; it also sends `POST /webhook "forged"` (401), sends `"signed"` to `/webhook/x`, and checks the statuses and texts but not that `webhook` is not called.

With header fields:

```mojo
from muntin import App, Headers, Request, Response


def webhook(req: Request) raises -> Response:
    var signature = req.headers.get("x-signature")      # Optional[String]
    if not signature or signature.value() != "sha256=valid":
        return Response.text("unsigned", status=401)
    var resp = Response.text("ok")
    resp.headers.add("X-Request-Id", "42")               # raises if invalid
    return resp^


var app = App()
app.post["/webhook"](webhook)
# POST /webhook  X-Signature: sha256=valid  -> 200 "ok", X-Request-Id: 42
# POST /webhook  (no X-Signature)           -> 401 "unsigned"
```

Run by `tests/test_headers.mojo` (`test_dx_section_9_headers_example`), which names the handler `dx_webhook` and sends both requests through `app.handle` (`Headers` builds the signed request's field).

- Same registration on all five methods; with [state](state.md#raw-handlers), `def(State[S], Request) -> Response`.
- The handler declares `req: Request` or `var req: Request` (an owned copy it may change or move `req.body` out of), and returns `Response` only. It may be non-raising, `raises` or `raises T`, under the [error model](errors.md).
- The route literal declares no placeholder. The route is selected by method and path as for typed routes (404, 405, first registration wins across raw and typed routes).
- The handler reads `req.method`, `req.path`, `req.query` (undecoded) and `req.body` exactly as the backend built them. Muntin runs no extraction and answers no 400 after the match; the handler may answer any status. A method or target that is not UTF-8 never reaches it (the Flare adapter answers 400 first).
- A raw `get` handler also answers `HEAD`, with `req.method == "HEAD"`, and must return the body it would give `GET` ([routing](routing.md#head)).
- Errors: on `post`, `def(req: Request) -> String` or `def(id: Int, req: Request)` is `constraint failed: Request is the whole request, not a body; a raw handler takes only the Request and returns Response`, and an extra parameter after the `Request` `a raw post handler takes only the Request and returns Response`; on `get` each is `a raw get handler takes only the Request and returns Response`.
- A typed function value is spelled `def(var Request) thin raises Never -> Response`.

## Binary bodies

A body is bytes, `List[UInt8]`, both ways:

```mojo
from muntin import App, Request, Response
from muntin.testing import TestClient


def upload(req: Request) raises -> Response:
    # Any bytes, as received, sent back byte for byte; Muntin adds no
    # Content-Type, so the handler sets its own.
    var r = Response(200, req.body.copy())
    r.headers.add("Content-Type", "application/octet-stream")
    return r^


def note(req: Request) raises -> Response:
    # `text()` raises if the body is not UTF-8.
    return Response.text("note: " + req.text())


var app = App()
app.post["/upload"](upload)
app.post["/note"](note)
var png: List[UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
var r = TestClient(app).post("/upload", png^)
# POST /upload  89 50 4E 47 0D 0A 1A 0A -> 200, the same 8 bytes, Content-Type: application/octet-stream
# POST /note    "hé"                    -> 200 "note: hé"
# POST /note    FF                      -> 500 "Internal Server Error"  (note's raise; it may catch it and answer 400)
```

Run by `tests/test_binary_body.mojo` (`test_dx_binary_example`), as written; it sends the two `/note` requests through a second `TestClient` on the same `App`.

- `Request.body` and `Response.body` are `List[UInt8]`: no step replaces, drops or adds a byte. `Response(status, bytes^)` and `Request(method, target, bytes^, headers^)` take bytes by move; the text constructors store UTF-8 bytes. Muntin adds, guesses or rewrites no `Content-Type`.
- `req.text()` and `response.text()` return a copy as text when the bytes are well-formed UTF-8 and raise otherwise. In a raw handler that raise is a handler error (the fixed 500); a handler that must answer 400 catches it, or compares bytes (`Span(req.body) == "signed".as_bytes()`).
- Middleware sees the request's bytes and may replace them (`request.body = new_bytes^`).
- Through Flare, over HTTP/1.1 (`Content-Length` or chunked) and h2c, a body within the `Server`'s `max_body_bytes` is never refused before `App.handle` for its bytes ([M3-040](../history/decisions/m3-040-binary-request-and-response-bodies-decision.md)): whatever they are, ones that are not UTF-8 included, they reach `App.handle` unchanged. That is not a promise to receive every such request: over HTTP/1.1 Flare also counts the head, chunk framing and any pipelined bytes against the limit plus 8 KiB, and Flare's own 400s and the adapter's 400s and 431 refuse a request whatever its body ([serving](serving.md#receive-body-limit)).
- Through Flare the response bytes go out as given; for `HEAD` the adapter sends no content and declares their byte count as `Content-Length`, and declares none for 1xx, 204, 205 and 304 ([routing](routing.md#head)).
- A typed handler takes bytes as a [`FromBytes`](bodies.md#binary-bodies-frombytes) body. Streaming and multipart bodies are not supported.
