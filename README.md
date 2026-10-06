# Muntin

Muntin is a typed application layer for building web services in Mojo. Your handlers depend on Muntin, not on sockets, reactors, TLS or a particular networking stack.

Muntin is pre-alpha and its public API is still changing. Today it is for exploring and testing typed web APIs in Mojo: applications run in memory through `TestClient`, and there is no supported way to serve one yet.

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

- A malformed route literal, or a route whose placeholders do not match the handler's route values, fails at the registration call. Binding is positional; names are not compared.
- On typed routes, a route value that does not convert, a missing or duplicated query value, or a body that does not convert is a 400, and the handler is not called. A JSON body gets 415 or 413 first for a wrong `Content-Type` or an oversized body.
- Anything a handler raises is a fixed 500 that never carries the error text, unless the handler's declared error type opts in to its own response.

Exact rules and messages: [`docs/DX.md`](docs/DX.md).

## Why Muntin

Networking stacks evolve: new protocols, new reactors, new TLS and QUIC implementations. Application code should not have to evolve with them.

Muntin owns the application contract: routes, typed extraction, results, errors, state, serialization and testing. A networking backend adapts to one operation, `App.handle(Request) -> Response`, and never defines what a route, a handler or an application error means. Muntin currently integrates with Flare behind this boundary, in tests only.

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
          /         \
         v           v
  in-memory       Flare
  TestClient      adapter
```

Your handlers and routes do not depend on Flare or on another networking runtime, and Muntin ships no executor or async runtime of its own. Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

The name comes from the window: a muntin is the narrow bar that divides and supports the panes. It holds the structure together without being what you look at.

## Kept honest by CI

CI enforces the transport boundary, unsafe-code confinement and the documented compile errors, and exercises the Flare adapter over a real loopback connection on Ubuntu and macOS.

## Status

Muntin is building toward a typed web framework whose routing, extraction, errors, middleware and testing stay independent of the networking stack.

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
