# Testing and the backend seam

## `TestClient`

`muntin.testing.TestClient` drives an `App` in memory, with no socket, through the same `App.handle` a network backend calls.

```mojo
from muntin import App, Request, Response
from muntin.testing import TestClient


def hello() -> String:
    return "hello"


def main() raises:
    var app = App()
    app.get["/hello"](hello)          # compile-time route literal, runtime handler value

    var client = TestClient(app)      # borrows the app; no socket
    var response = client.get("/hello")
    # response.status == 200, response.text() == "hello"

    var direct = app.handle(Request("GET", "/hello"))  # backend seam
    var custom = Response.text("ok", status=201)
```

- `TestClient(app)` borrows the `App` and copies nothing.
- `get(target)`, `head(target)`, `post(target, body)`, `put(target, body)`, `patch(target, body)` and `delete(target)` build `Request(method, target, body, headers^)` and call `App.handle`, nothing else. `body` is text, or bytes as a `List[UInt8]` moved in (`client.post("/upload", png^)`); `head` and `delete` send an empty body (a test that sends a `HEAD` or `DELETE` body builds the `Request` and calls `app.handle`).
- Each takes the request's fields as a keyword-only `headers=`, moved in; without it no field is sent. The client adds, removes or merges no field, so its answer equals `app.handle(Request(...))` built from the same parts:

```mojo
var headers = Headers()
headers.add("X-Request-Id", "42")
_ = client.get("/echo", headers=headers.copy())    # headers stays usable
_ = client.post("/echo", "body", headers=headers^)  # moved
_ = client.get("/echo")                             # no fields
```

- A positional `Headers` is `invalid call to 'get'` (`unexpected argument`), or on `post`, `put` and `patch` `no matching method`. A plain variable is `cannot be implicitly copied`: pass `headers^` or `headers.copy()`. Building `Headers` raises, so a test that sends fields runs in a raising context.
- A JSON body route answers a request without `Content-Type` 415, so send the field.
- `head(target)` returns `App.handle`'s answer unchanged, body included. It applies no wire rule: it removes no body and declares no `Content-Length`, for 204, 205 and 304 too. Test what goes on the wire through a network backend ([M3-036](../history/architecture-decisions.md#testclient-head-decision-m3-036)).
- A `TestClient` exercises one `App`; it says nothing about how a server uses several (workers).

## The backend seam

The only seam between Muntin and a backend is `App.handle`, in two overloads that answer alike:

- handed over: `app.handle(request^)`, or a temporary such as `app.handle(Request("GET", "/hello"))`;
- lent: `app.handle(request)`, a named value the caller keeps.

`TestClient` and the Flare adapter hand their request over. When middleware is registered, the lent overload copies the request once (body included) for the chain; the handed-over one does not.

A backend builds a Muntin `Request` from the raw target (undecoded), passes body bytes unchanged both ways, and converts the `Response` back. What every network backend owes Muntin: one `App` never called from two threads at once, the raw target, body bytes unchanged both ways, and a `HEAD` answer with no content and the `GET`'s length ([architecture](../ARCHITECTURE.md#backend-seam)).

What a change of backend keeps is the application's source: handlers, middleware, `State` types, registrations, how an `App` is built, and tests through `TestClient`. It does not keep serving: `Server`, its settings, its threads and workers, its stop and Flare's own refusals belong to the Flare adapter ([serving](serving.md)). It also does not keep an `App` on one thread: a backend that calls one from several threads in turn must order the calls, and `State` values must then be safe on another thread, which Muntin cannot check. No second network backend exists, so none of this is demonstrated ([M3-070](../history/architecture-decisions.md#backend-coupling-decision-m3-070)).
