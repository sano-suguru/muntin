# Testing and the backend seam

## `TestClient`

`muntin.testing.TestClient` drives an `App` in memory, with no socket, through the same `App.handle` a network backend calls. Each example below is its own `App`; the line after it names the test that runs it, or the nearest one, and what that test adds or changes.

<!-- example: tests/test_reference_examples.mojo#testing-client client_example=main client_app=make_app -->
```mojo
from muntin import App, Request, Response
from muntin.testing import TestClient


def hello() -> String:
    return "hello"


def make_app() -> App:
    var app = App()
    app.get["/hello"](hello)          # compile-time route literal, runtime handler value
    return app^


def main() raises:
    var app = make_app()
    var client = TestClient(app)      # borrows the app; no socket
    var response = client.get("/hello")
    print(response.status, response.text())            # 200 hello

    var direct = app.handle(Request("GET", "/hello"))  # backend seam
    print(direct.status, direct.text())                # 200 hello
    var custom = Response.text("ok", status=201)
    print(custom.status, custom.text())                # 201 ok
```

Run by `tests/test_reference_examples.mojo` (`test_testing_client`), with `main` named `client_example` and `make_app` named `client_app`: the test calls `main`, then checks the three answers, the first two from the `App` that `make_app` returns. `tests/test_app.mojo` also runs its parts: `test_get_hello_through_test_client` (the `TestClient` request, checking 200 and `"hello"`), `test_get_hello_through_backend_seam` (the same answer from `app.handle(Request("GET", "/hello"))`) and `test_response_text_constructor` (status 201, text `"ok"`). `main.mojo` is the `TestClient` part as a program that prints the status and text.

- `TestClient(app)` borrows the `App` and copies nothing.
- `get(target)`, `head(target)`, `post(target, body)`, `put(target, body)`, `patch(target, body)` and `delete(target)` build `Request(method, target, body, headers^)` and call `App.handle`, nothing else. `body` is text, or bytes as a `List[UInt8]` moved in (`client.post("/upload", png^)`); `head` and `delete` send an empty body (a test that sends a `HEAD` or `DELETE` body builds the `Request` and calls `app.handle`).
- Each takes the request's fields as a keyword-only `headers=`, moved in; without it no field is sent. The client adds, removes or merges no field, so its answer equals `app.handle(Request(...))` built from the same parts:

<!-- example: tests/test_reference_examples.mojo#testing-header-fields header_fields_example=main echo_app=make_app -->
```mojo
from muntin import App, Headers, Request, Response
from muntin.testing import TestClient


def echo(req: Request) -> Response:                 # answers with every field it received
    var out = req.method + " " + req.path
    for i in range(len(req.headers)):
        out += " " + req.headers.name(i) + "=" + req.headers.value(i)
    return Response.text(out)


def make_app() -> App:
    var app = App()
    app.get["/echo"](echo)
    app.post["/echo"](echo)
    return app^


def main() raises:                                   # building Headers raises
    var app = make_app()
    var client = TestClient(app)
    var headers = Headers()
    headers.add("X-Request-Id", "42")
    _ = client.get("/echo", headers=headers.copy())    # headers stays usable: "GET /echo X-Request-Id=42"
    _ = client.post("/echo", "body", headers=headers^)  # moved: "POST /echo X-Request-Id=42"
    _ = client.get("/echo")                             # no fields: "GET /echo"
```

Run by `tests/test_reference_examples.mojo` (`test_testing_header_fields`), with `main` named `header_fields_example` and `make_app` named `echo_app`: the test calls `main`, then sends the same requests to the `App` that `make_app` returns and checks the answers its comments state. `tests/test_testclient_headers.mojo` checks that each answer equals `app.handle` given the same parts (`test_get_with_headers`, `test_post_with_headers`) and that a request already sent keeps its fields (`test_ownership_follows_request`).

- A positional `Headers` is `invalid call to 'get'` (`unexpected argument`), or on `post`, `put` and `patch` `no matching method`. A plain variable is `cannot be implicitly copied`: pass `headers^` or `headers.copy()`. Building `Headers` raises, so a test that sends fields runs in a raising context.
- A JSON body route answers a request without `Content-Type` 415, so send the field.
- `head(target)` returns `App.handle`'s answer unchanged, body included. It applies no wire rule: it removes no body and declares no `Content-Length`, for 204, 205 and 304 too. Test what goes on the wire through a network backend ([M3-036](../history/decisions/m3-036-testclient-head-decision.md)).
- A `TestClient` exercises one `App`; it says nothing about how a server uses several (workers).

## The backend seam

The only seam between Muntin and a backend is `App.handle`, in two overloads that answer alike:

- handed over: `app.handle(request^)`, or a temporary such as `app.handle(Request("GET", "/hello"))`;
- lent: `app.handle(request)`, a named value the caller keeps.

`TestClient` and the Flare adapter hand their request over. When middleware is registered, the lent overload copies the request once (body included) for the chain; the handed-over one does not.

A backend builds a Muntin `Request` from the raw target (undecoded), passes body bytes unchanged both ways, and converts the `Response` back. What every network backend owes Muntin: one `App` never called from two threads at once, the raw target, body bytes unchanged both ways, and a `HEAD` answer with no content and the `GET`'s length ([architecture](../ARCHITECTURE.md#backend-seam)).

What a change of backend keeps is the application's source: handlers, middleware, `State` types, registrations, how an `App` is built, and tests through `TestClient`. It does not keep serving: `Server`, its settings, its threads and workers, its stop and Flare's own refusals belong to the Flare adapter ([serving](serving.md)). It also does not keep an `App` on one thread: a backend that calls one from several threads in turn must order the calls, and `State` values must then be safe on another thread, which Muntin cannot check. No second network backend exists, so none of this is demonstrated ([M3-070](../history/decisions/m3-070-backend-coupling-decision.md)).
