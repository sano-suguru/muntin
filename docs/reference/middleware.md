# Middleware

Middleware is a function ([M3-034](../history/decisions/m3-034-middleware-decision.md)). Each example below is its own `App`; the line after it names the test that runs it and what that test adds or changes.

<!-- example: tests/test_middleware.mojo#middleware-tracing tracing_app=make_app -->
```mojo
from muntin import App, Next, Request, Response


def tracing(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    response.headers.add("X-Trace", "1")
    return response^


def hello() -> String:
    return "hello"


def make_app() -> App:
    var app = App()
    app.use(tracing)
    app.get["/hello"](hello)
    return app^
# GET /hello    -> 200 "hello"; X-Trace: 1
# GET /missing  -> 404 "Not Found"; X-Trace: 1
# POST /hello   -> 405 "Method Not Allowed"; Allow: GET, HEAD; X-Trace: 1
```

Run by `tests/test_middleware.mojo` (`test_the_dx_example_as_written`), with `make_app` named `tracing_app`: the test sends the requests to the `App` it returns, `POST /hello` with an empty body.

- `app.use(f)` takes `def(var request: Request, var next: Next) raises -> Response`; one that borrows the request or does not raise converts too. The type is public as `Middleware`. A middleware may change the request, answer without running the rest, or run the rest with `next^.run(request^)` and change or replace the response.
- `next^.run(request^)` consumes `next`, so the rest runs at most once: a second use, or one in a loop, does not compile (`use of uninitialized value 'next'`); `Next` has no plain call and no copy. A `Next` moved into a container and taken twice aborts the process at the second `take()`. A `Next` cannot outlive the call that received it. Code that names `_`-prefixed members or applies unsafe pointer operations or `rebind_var` to a `Next` is outside these guarantees.
- Scope and order: every request `App.handle` receives (404, 405, 400s, a handler's 500 and `HEAD` included), in registration order, outermost first, wherever `use` sits among the routes: `a` then `b` see the request as `a`, `b` and the response as `b`, `a`.
- `HEAD` arrives as `HEAD`; the backend drops the content of whatever comes out and declares its length, so a middleware must answer `HEAD` with the body it would give `GET` ([routing](routing.md#head)).
- Requests a backend refuses before `App.handle` never reach middleware: through Flare, its own 400s, a body over `max_body_bytes`, the adapter's 400s (a method, target or field it cannot represent, a missing or invalid `Host`) and 431. A body within `max_body_bytes` is never refused before `App.handle` for its bytes ([M3-040](../history/decisions/m3-040-binary-request-and-response-bodies-decision.md)): a request that reaches `App.handle` reaches middleware with its body's bytes, ones that are not UTF-8 included, so a middleware that reads `request.text()` handles its raise. Such a request can still be refused for the reasons above, and over HTTP/1.1 Flare counts its head, chunk framing and pipelined bytes against the limit plus 8 KiB ([serving](serving.md#receive-body-limit)).
- A middleware that does not touch a response passes it through unchanged. One that builds or changes a 405 owns its `Allow`.
- Errors: a raise out of a middleware is the fixed 500 at that middleware's call, with no error text on the wire; the middleware outside it receives that 500 from `next`, carrying a `Failure.MIDDLEWARE` report ([errors](errors.md#reports-of-dropped-errors)), and continues. A raise before `next^.run` leaves the rest uncalled.
- Configuration is compile-time only, through the function's parameters: `app.use(tagged["v1"])` for `def tagged[value: StaticString](var request: Request, var next: Next) raises -> Response`. A closure that captures a runtime value does not convert (`cannot be converted from ... to 'Middleware'`).
- Not supported: runtime-configured middleware (a value read at start-up), request-scoped typed context, per-route or per-group middleware, middleware error types, async. A [guarded group](groups.md)'s guard reads start-up values and hands its handlers a typed value.
- **A field middleware writes is not a way to hand a handler an authenticated identity**: middleware can allow or deny a request, but request header fields are client input (a client can send the same name itself), so an application must not use such a field as an identity. A guard hands one to a handler as a typed value ([groups](groups.md)).
- Cost: an `App` with no middleware dispatches as before. With middleware, each is one call, one `Next` and one level of nested calls. A request handed over (`app.handle(request^)`, as `TestClient` and the Flare adapter do) reaches the first middleware without a copy; a named request lent to `App.handle` is copied once, body included ([testing](testing.md#the-backend-seam)).

## Logging dropped errors

A middleware registered first receives every response the others and the routes make, with its report:

<!-- example: tests/test_failure.mojo#middleware-logging -->
```mojo
from std.sys import stderr

from muntin import App, Failure, Next, Request, Response


def quoted(text: String) -> String:
    """`text` in double quotes, each byte outside printable ASCII, `"` and
    `\\` written as `\\xNN`: no control character reaches the log as itself.
    """
    var out = String('"')
    for b in text.as_bytes():
        var c = Int(b)
        if c < 0x20 or c > 0x7E or c == 0x22 or c == 0x5C:
            out += "\\x"
            for d in [c >> 4, c & 15]:
                out += chr(d + 48 if d < 10 else d + 87)
        else:
            out += chr(c)
    return out + '"'


def failure_line(
    method: String, path: String, request_id: String, failure: Failure
) -> String:
    # Every value but `source` comes from the client or the error, so each is
    # quoted; masking secrets is the application's.
    return String(
        quoted(method),
        " ",
        quoted(path),
        " client-id=",
        quoted(request_id),
        " ",
        failure.source,
        ": ",
        quoted(failure.message),
    )


def log_failures(var request: Request, var next: Next) raises -> Response:
    var method = request.method  # kept: `next` takes the request
    var path = request.path
    var request_id = request.headers.get("X-Request-Id").or_else("-")
    var response = next^.run(request^)
    var failure = response.failure()
    if failure:
        print(
            failure_line(method, path, request_id, failure.value()),
            file=stderr,
        )
    return response^


var app = App()
app.use(log_failures)  # first, so outside every other middleware
app.get["/orders/{id}"](find_order)  # find_order from errors.md
# GET /orders/0 with X-Request-Id: r-1 -> 500 "Internal Server Error"; standard error:
#   "GET" "/orders/0" client-id="r-1" handler: "database password is hunter2"
```

`find_order` is the handler of [errors](errors.md#reports-of-dropped-errors). Run by `tests/test_failure.mojo` (`test_dx_logging_example`), as written; it checks only the 500, its `Failure.HANDLER` report and `GET /orders/1`: the standard-error line is not asserted. That line is checked in `test_outermost_logging_middleware`, through a twin `logged` that writes it into an `X-Log` field instead, for the target `/orders/0?q=1`.

- Register it first: a middleware outside it that raises makes a report it never sees.
- A request ID a client sends is client input: it correlates log lines and is not trusted. Muntin has no request ID, timing, metrics or tracing.
- Escaping and masking are the application's. `quoted` writes every byte outside printable ASCII, `"` and `\` as `\xNN`, so nothing can end the line, move the cursor or reorder its text; it masks nothing. `repr` is not enough: it leaves C1 controls and other non-ASCII characters as they are.
