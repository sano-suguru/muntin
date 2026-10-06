# Muntin

Muntin is a typed application layer for building web services in Mojo. Your handlers depend on Muntin, not on sockets, reactors, TLS or a particular networking stack.

Muntin is pre-alpha and its public API is still changing. Today it is for building and testing typed web application logic: applications run in memory through `TestClient`, and there is no supported way to serve one yet.

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

Muntin rejects, at compile time, a route whose placeholders do not match the handler's parameters. At runtime, typed inputs that do not convert are rejected before your handler runs, and an error your handler raises becomes a 500 that does not leak its text unless its type opts in to its own response. Exact rules and messages: [`docs/DX.md`](docs/DX.md).

## Why Muntin

Networking stacks evolve: new protocols, new reactors, new TLS and QUIC implementations. Application code should not have to evolve with them.

Muntin owns the application contract: how routes call handlers, how inputs become typed values, and how results and errors become responses. A networking backend adapts to one operation, `App.handle(Request) -> Response`, and never defines that contract. Muntin currently integrates with Flare behind this boundary, in tests only.

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
  in memory         over HTTP (tests only)
```

Your handlers and routes stay independent of Flare or any other networking runtime, and Muntin adds no executor or async runtime that application code must adopt. Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

The name comes from the window: a muntin is the narrow bar that divides and supports the panes. It holds the structure together without being what you look at.

## Kept honest by CI

CI enforces the transport boundary, unsafe-code confinement and the documented compile errors, and exercises the Flare adapter over a real loopback connection on Ubuntu and macOS.

## Status

- **Today:** typed routing (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`), one `Int` or `String` route value per route (path or query), typed request bodies and results (including JSON), application errors, shared application state, headers, and a raw `Request -> Response` escape hatch.
- **Not yet:** serving an application (serving through Flare is test code only, and Flare is a candidate production backend, not a supported deployment path) and middleware.

Shipped and remaining capabilities: [`docs/SPEC.md`](docs/SPEC.md). Long-term API targets: [`docs/DX.md`](docs/DX.md).

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
