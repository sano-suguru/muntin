# Muntin

Muntin is a typed application layer for building web services in Mojo. Your handlers depend on Muntin, not on Flare or another networking runtime.

**Pre-alpha and not production-ready:** the public API is still changing.

## What it is for today

- **Use it for** short synchronous HTTP APIs, such as ones calling existing Mojo code, and for testing typed application logic in memory with `TestClient`.
- **Avoid** long computations inside a handler. Handlers run one at a time per worker thread: while one runs, its worker answers nothing else, on any connection or h2c stream, and requests waiting on kept-open connections can be closed unanswered once it returns, past `idle_timeout_ms`. Run long work outside the server process, and let the handler hand it off ([serving](docs/reference/serving.md#one-request-at-a-time)).
- **Works today:** typed routes and route values, JSON and binary bodies, typed results and errors, shared read-only state, header fields, middleware functions, raw `Request -> Response` handlers, in-memory testing, and serving over HTTP/1.1, h2c or HTTPS from an IP-literal host, on one or several worker threads, with a graceful stop.
- **Serious limits:**
  - A stop does not cancel or notify running handlers; if the server has not stopped one second after its grace window, the process ends without cleanup ([stopping](docs/reference/serving.md#stopping)).
  - Middleware is configured at compile time and runs on every request; no typed request-scoped value, such as an authenticated user, passes from middleware to a handler (a middleware can only change the request).
  - JSON fields are mapped by hand, so a misspelled key compiles; a `Float64` written may not read back the same ([JSON](docs/reference/bodies.md#json-jsont)). Route values bind by position; names are checked only through `Param` and `RouteValues` ([route values](docs/reference/route-values.md)).
  - `State` judges whether a type may borrow by reading its name: it refuses some owned types (`Tuple`, `Variant`), and a type hiding `AnyOrigin` behind an associated type passes, letting a handler read freed memory in safe code ([state](docs/reference/state.md)).
  - Not built: streaming, cancellation, OpenAPI, CORS preflight, logging, metrics, tracing ([candidates](docs/SPEC.md#remaining-candidates)).
  - Flare is the only network backend. Application code is kept apart from it, but a move to another backend is untested, and serving (`Server`, its settings, workers, stop) would be rewritten ([backend seam](docs/reference/testing.md#the-backend-seam)).
  - With a browser's request fields, a handler doing nothing serves 25–38% fewer HTTP/1.1 requests per second than on Flare alone ([M3-079](docs/history/decisions/m3-079-comparison-with-flare-alone-decision.md)).
- **Verified with** Mojo 1.1.0 (8189361e) and Flare v0.12.0, on Linux and macOS, by CI on each pull request that changes code (tests, the transport boundary, unsafe confinement, compile errors, the adapter over loopback, the unsafe storage under AddressSanitizer on Linux) ([verification](docs/DEVELOPMENT.md#3-verify-with-the-strongest-available-oracle)). To reproduce CI's checks after installing [pixi](https://pixi.sh):

```sh
pixi install
./scripts/check.sh && ./scripts/test.sh && ./scripts/check_flare.sh
```

## A first application

<!-- example: tests/test_guide.mojo#first-application first_application=main -->
```mojo
from muntin import App
from muntin.testing import TestClient


def get_user(id: Int) -> String:
    return "user " + String(id)


def make_app() -> App:
    var app = App()
    app.get["/users/{id}"](get_user)
    return app^


def main() raises:
    var app = make_app()
    var client = TestClient(app)        # in memory, no socket
    print(client.get("/users/42").text())   # user 42
```

## Your handler receives valid values

```text
GET /users/42   -> 200 "user 42"       get_user receives Int(42)
GET /users/abc  -> 400 "Bad Request"   get_user is never called
GET /users      -> 404 "Not Found"
```

A route that does not fit its handler does not compile:

<!-- example: tests/compile_fail/param_route_no_arg_handler.mojo#readme -->
```mojo
def hello() -> String:
    return "hello"


app.get["/users/{id}"](hello)
# compile error: route declares a path parameter but the handler takes none
```

Muntin rejects route and handler shape mismatches at compile time. At runtime, typed inputs that do not convert are rejected before your handler runs. Handler errors become 500 responses that do not leak their text, unless their declared type opts in to its own response. How to use it: [`docs/GUIDE.md`](docs/GUIDE.md); exact rules and messages: [`docs/reference/`](docs/reference/).

## Why Muntin

Networking stacks evolve: new protocols, new reactors, new TLS and QUIC implementations. Application code should not have to evolve with them.

Muntin owns the application contract: how routes call handlers, how inputs become typed values, and how results and errors become responses. A networking backend adapts to one operation, `App.handle(Request) -> Response`, and never defines that contract. Muntin currently integrates with Flare behind this boundary.

```text
application code
      |
      v
+--------------------------+
| Muntin public API        |
| App / Request / Response |
| routes / handlers        |
+-------------+------------+
              |
   App.handle(Request) -> Response
         /             \
        v               v
  TestClient        Flare adapter
  in memory         over HTTP (Server)
```

Your handlers and routes import nothing from Flare, and Muntin adds no executor or async runtime that application code must adopt. That a second backend could replace Flare is a design aim, not a demonstrated fact (above). Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

The name comes from the window: a muntin is the narrow bar that divides and supports the panes. It holds the structure together without being what you look at.

## Try it

Muntin is not published as a package yet. You need [pixi](https://pixi.sh), which installs the pinned Mojo toolchain:

```sh
git clone https://github.com/sano-suguru/muntin.git
cd muntin
pixi install
pixi run run   # runs main.mojo: an App answering one request through TestClient
```

To run the example above, save it as `example.mojo` in the repository root and run `pixi run mojo run -I src example.mojo`.

To serve [`examples/hello_server.mojo`](examples/hello_server.mojo) on `http://127.0.0.1:8080` (it needs the `flare` environment, which pixi builds from Flare's pinned source on first use):

```sh
pixi run -e flare mojo run -I src -I adapters/flare examples/hello_server.mojo
```

`server.serve(app)` blocks, so the server keeps running in that terminal. In another terminal:

```sh
curl http://127.0.0.1:8080/   # Hello, Mojo!
```

To serve the same app over HTTPS, give `Server.bind` a certificate and its key ([`examples/hello_https.mojo`](examples/hello_https.mojo)). For a local try, make a self-signed pair with the `flare` environment's OpenSSL, serve on `https://127.0.0.1:8443`, and trust that certificate in the client:

```sh
pixi run -e flare openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout key.pem -out cert.pem -days 30 -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1
pixi run -e flare mojo run -I src -I adapters/flare examples/hello_https.mojo
curl --cacert cert.pem https://127.0.0.1:8443/   # Hello, Mojo! (in another terminal)
```

In production, use a certificate from your certificate authority; a wrong file stops `Server.bind` with an error naming it ([`docs/reference/serving.md`](docs/reference/serving.md#https)).

### From your own project

Until Muntin is packaged, your project uses a clone of it and passes its sources to `mojo` with `-I`. Put the clone next to your project; your program then runs against whatever commit the clone has checked out:

```text
workspace/
├── muntin/      git clone https://github.com/sano-suguru/muntin.git
└── myapp/
    ├── pixi.toml
    └── app.mojo
```

`myapp/pixi.toml` needs Muntin's channels and Mojo, in the range Muntin's own `pixi.toml` declares (Muntin is checked only with the toolchain named under [What it is for today](#what-it-is-for-today); your `pixi.lock` records the version you get):

```toml
[workspace]
name = "myapp"
channels = ["https://conda.modular.com/max", "conda-forge"]
platforms = ["linux-64", "osx-arm64"]

[dependencies]
mojo = ">=1.1.0,<2"
```

```sh
pixi run mojo run -I ../muntin/src app.mojo    # App and TestClient
```

To serve with `muntin_flare`'s `Server`, also add Flare, at the tag Muntin's own `pixi.toml` pins, and pass the adapter's directory too. These keys go into the `[workspace]` and `[dependencies]` tables above; a second copy of either header makes the file invalid TOML:

```toml
[workspace]
preview = ["pixi-build"]   # pixi builds Flare from its git source

[dependencies]
flare = { git = "https://github.com/ehsanmok/flare.git", tag = "v0.12.0" }
```

```sh
pixi run mojo run -I ../muntin/src -I ../muntin/adapters/flare app.mojo
```

`mojo build` takes the same `-I` paths.

## Documentation

- [`docs/GUIDE.md`](docs/GUIDE.md): how to write Muntin applications, feature by feature.
- [`docs/reference/`](docs/reference/): the API by topic: accepted shapes, statuses, diagnostics, examples.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): how Muntin works now: boundaries, invariants, current limits.
- [`docs/history/architecture-decisions.md`](docs/history/architecture-decisions.md): why: one record per design decision, each marked current, superseded or withdrawn.
- [`docs/SPEC.md`](docs/SPEC.md): product scope, shipped capabilities and the next candidates; future work is in GitHub issues.
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md): verification commands, CI, and which document owns what.
- [`docs/REFERENCES.md`](docs/REFERENCES.md): upstream sources and the Flare pin.

## Development

The toolchain is managed by pixi and pinned in `pixi.lock`. What each check script covers and how to work on Muntin: [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md). `pixi run format` formats sources.

## License

[MIT](LICENSE)
