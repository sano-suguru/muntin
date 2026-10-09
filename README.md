# Muntin

Muntin is a typed application layer for building web services in Mojo. Your handlers depend on Muntin, not on Flare or another networking runtime.

Muntin is pre-alpha and its public API is still changing. Today it is for building and testing typed web application logic: applications run in memory through `TestClient`, and the Flare adapter's `Server` serves one over cleartext HTTP on one thread, with an IP-literal host and no graceful shutdown. It is not production-ready.

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

Muntin rejects route and handler shape mismatches at compile time. At runtime, typed inputs that do not convert are rejected before your handler runs. Handler errors become 500 responses that do not leak their text, unless their declared type opts in to its own response. Exact rules and messages: [`docs/DX.md`](docs/DX.md).

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
  in memory         over HTTP (Server, one thread)
```

Your handlers and routes stay independent of Flare or any other networking runtime, and Muntin adds no executor or async runtime that application code must adopt. Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

The name comes from the window: a muntin is the narrow bar that divides and supports the panes. It holds the structure together without being what you look at.

## Kept honest by CI

CI enforces the transport boundary, unsafe-code confinement and the documented compile errors, and exercises the Flare adapter over a real loopback connection on Ubuntu and macOS.

## Status

- **Today:** typed routing, typed request bodies and results (including JSON), application errors, shared application state, headers, and a raw `Request -> Response` escape hatch.
- **Serving:** `Server` in the Flare adapter module (`muntin_flare`) serves an `App` over cleartext HTTP/1.1 and HTTP/2 with prior knowledge, on one thread. Its limits: no graceful shutdown (SIGINT, from Ctrl-C, or SIGTERM ends the process and cuts in-flight requests, unless the process inherited the signal ignored), an IP literal as the host (`"127.0.0.1"`, `"0.0.0.0"`, `"::1"`; not `"localhost"`), no TLS or HTTP/3, Flare's default limits (such as a 10 MiB body), no backend configuration, and it runs from a clone with two `-I` paths, not from a published package. Details: [`docs/DX.md`](docs/DX.md) section 1.
- **Not yet:** middleware, and serving beyond those limits.

Shipped and remaining capabilities: [`docs/SPEC.md`](docs/SPEC.md). Long-term API targets: [`docs/DX.md`](docs/DX.md).

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
curl http://127.0.0.1:8080/   # Hello, Mojo!
```

## Documentation

- [`docs/DX.md`](docs/DX.md): how to write Muntin applications: API, examples, semantics.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): how Muntin works now: boundaries, invariants, current limits.
- [`docs/history/architecture-decisions.md`](docs/history/architecture-decisions.md): why: one record per design decision.
- [`docs/SPEC.md`](docs/SPEC.md): product scope and roadmap.
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md): verification commands, CI, and which document owns what.
- [`docs/REFERENCES.md`](docs/REFERENCES.md): upstream sources and the Flare pin.

## Development

Toolchain: **Mojo 1.1.0 (8189361e)**, managed by pixi (pinned in `pixi.lock`; `scripts/check.sh` fails on any other Mojo version).

```sh
pixi install
./scripts/check.sh   # toolchain version, formatting, architecture boundary, unsafe confinement, package + example build, must-not-compile fixtures
./scripts/test.sh    # executable tests in tests/test_*.mojo
git diff --check
./scripts/check_flare.sh  # Flare compatibility + adapter contract tests (separate `flare` environment)
```

`pixi run check` and `pixi run test` run the same scripts. `pixi run format` formats sources.
