# Muntin

Muntin is a typed application layer for building web services in Mojo. Your handlers depend on Muntin, not on sockets, reactors, TLS or a particular networking stack.

Muntin is pre-alpha: the public API is still changing.

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

This runs today on the pinned toolchain. What it shows:

```text
GET /users/42   -> 200 "user 42"       get_user receives Int(42)
GET /users/abc  -> 400 "Bad Request"   get_user is never called
GET /users      -> 404 "Not Found"
```

And a route that does not fit its handler is not an application at all:

```mojo
def hello() -> String:
    return "hello"

app.get["/users/{id}"](hello)
# compile error: route declares a path parameter but the handler takes none
```

## Why Muntin

Networking stacks evolve: new protocols, new reactors, new TLS and QUIC implementations. Application code should not have to evolve with them.

Muntin owns the application contract: routes, typed extraction, results, errors, state, serialization and testing. A networking backend adapts to one operation,

```text
App.handle(Request) -> Response
```

and never defines what a route, a handler or an error means. Flare is one such backend. It is not your application API.

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

What Muntin deliberately does not do:

- **No framework-owned runtime.** Muntin publishes no executor, future or task model of its own; sockets, TLS, HTTP/2, HTTP/3 and QUIC belong to backends.
- **No transport types in application code.** Handlers, routes and state never mention Flare.
- **No speculative backend abstraction.** There is no backend trait until a second backend exists; until then the seam is that one method.

The name comes from the window: a muntin is the narrow bar that divides and supports the panes. It holds the structure together without being what you look at.

## Invalid applications fail early

Muntin rejects what it can at compile time and answers bad requests before your handler runs:

- **At compile time:** a malformed route literal, or a route whose path and query parameters do not fit the handler's parameters, fails at the registration call with a message naming the rule it breaks.
- **Before the handler:** a route value that does not convert (`/users/abc` for an `Int`), a missing or duplicated query value, or a body that does not convert is a 400, and the handler is not called.
- **After the handler:** anything a handler raises is a fixed 500 whose body never contains the error text, unless the handler's declared error type opts in to answering with its own response.

The exact rules and messages are in [`docs/DX.md`](docs/DX.md).

## Kept honest by CI

The architecture is checked, not just drawn:

- **Boundary check:** `scripts/check.sh` fails if Muntin's core imports or mentions Flare or socket modules.
- **Unsafe confinement:** unsafe pointer and ownership operations live in one private storage module, and the check fails if they appear in any other module.
- **Must-not-compile fixtures:** the compile-time rules are pinned by programs that must fail to build with the documented message, and CI checks that they still do.
- **Same app, two backends:** behavior that crosses the backend seam is exercised in memory through `TestClient` and over a real loopback connection through the Flare adapter, on Ubuntu and macOS.

## Status

Muntin today handles typed routing (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`), `Int` and `String` route values, typed request bodies and results (including JSON), application errors, shared application state, headers, and a raw `Request -> Response` escape hatch.

There is no public API for serving an application yet: no `app.run()`, and serving through Flare is test code only. Middleware is not implemented. Flare is a candidate production networking backend, not a supported deployment path. Shipped and remaining capabilities are listed in [`docs/SPEC.md`](docs/SPEC.md).

The design target, which `docs/DX.md` tracks section by section, keeps the same shape and adds serving:

```mojo
def main():
    var app = App()
    app.get["/"](hello)
    app.run()   # target, not yet implemented
```

When the current Mojo toolchain cannot express a target form, the limitation is reproduced in a minimal program and documented, and Muntin ships the closest type-safe alternative.

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
