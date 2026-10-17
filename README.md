# Muntin

Muntin is a typed application layer for building web services in Mojo. Your handlers depend on Muntin, not on Flare or another networking runtime.

Muntin is pre-alpha and its public API is still changing. Today it is for building and testing typed web application logic: applications run in memory through `TestClient`, and the Flare adapter's `Server` serves one over HTTP or HTTPS, with an IP-literal host. On SIGTERM or SIGINT it stops taking connections and serves the open ones for a grace window; it does not cancel or notify running handlers, and if the server has not stopped one second after the window, it ends the whole process without cleanup. It is not production-ready.

```mojo
from muntin import App
from muntin.testing import TestClient


def get_user(id: Int) -> String:
    return "user " + String(id)


def main() raises:
    var app = App()
    app.get["/users/{id}"](get_user)

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

Your handlers and routes stay independent of Flare or any other networking runtime, and Muntin adds no executor or async runtime that application code must adopt. Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

The name comes from the window: a muntin is the narrow bar that divides and supports the panes. It holds the structure together without being what you look at.

## Kept honest by CI

CI enforces the transport boundary, unsafe-code confinement and the documented compile errors, and exercises the Flare adapter over a real loopback connection on Ubuntu and macOS.

## Status

- **Today:** typed routing, typed request bodies and results (including JSON and binary bodies), application errors, shared application state, headers, middleware functions (`app.use`), and a raw `Request -> Response` escape hatch.
- **Serving:** the Flare adapter's `Server` serves an `App` over cleartext HTTP/1.1 and h2c, or over HTTPS with `tls=Tls(cert_file=..., key_file=...)`, on one thread or on several workers with one `App` each, from an IP-literal host, and on SIGTERM or SIGINT serves the open connections for a grace window, then returns, or ends the process if it has not stopped one second later (no handler is cancelled or notified). Its settings and limits: [`docs/reference/serving.md`](docs/reference/serving.md).
- **Not yet:** see [`docs/SPEC.md`](docs/SPEC.md), "Remaining candidates".

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

`myapp/pixi.toml` needs Muntin's channels and Mojo, in the range Muntin's own `pixi.toml` declares (Muntin is checked only with the toolchain named under [Development](#development); your `pixi.lock` records the version you get):

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

Toolchain: **Mojo 1.1.0 (8189361e)**, managed by pixi and pinned in `pixi.lock`. After `pixi install`, `./scripts/check.sh`, `./scripts/test.sh` and `./scripts/check_flare.sh` are the checks CI runs; what each covers and how to work on Muntin: [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md). `pixi run format` formats sources.

## License

[MIT](LICENSE)
