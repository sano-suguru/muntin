# Muntin

Muntin is an experimental, typed web application framework for Mojo.

The project is deliberately focused on the layer above networking: application routing, typed extraction, validation, serialization, middleware, errors, observability, testing, and developer experience. Networking implementations live behind a narrow adapter boundary.

Muntin is pre-alpha: the public API is still changing.

## Why Muntin

A muntin is a narrow structural member that divides and supports panes in a window. The name fits the architectural goal: keep application code cleanly separated from replaceable transport/runtime implementations without making that boundary the center of the developer experience.

The durable bet is:

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
       narrow backend seam
          /         \
         v           v
  in-memory       Flare
  reference       adapter
  backend
```

Flare is a candidate production networking backend. It is not part of Muntin's public application contract.

## Target developer experience

The long-term direction is intentionally small and typed:

```mojo
from muntin import App


def hello() -> String:
    return "Hello, Mojo!"


def main():
    var app = App()
    app.get["/"](hello)
    app.run()
```

For typed path parameters, the desired direction is:

```mojo
def get_user(id: Int) -> User:
    return users.get(id)

app.get["/users/{id}"](get_user)
```

These examples are design targets, not claims that every syntax form is already supported by the current Mojo toolchain. `docs/DX.md` defines how to handle language limitations: prove the limitation with a minimal reproduction, document it, then choose the closest type-safe syntax.

## What it does

Muntin handles typed routing, request bodies and results (including JSON), application errors, shared application state, headers and a raw `Request -> Response` escape hatch, in memory through `TestClient` and over HTTP through the Flare adapter. There is no public API for serving an application yet. Shipped and remaining capabilities: `docs/SPEC.md`; exact usage and semantics: `docs/DX.md`.

## Repository guide

- `docs/DX.md` — how to write Muntin applications: API, examples, semantics.
- `docs/ARCHITECTURE.md` — how Muntin works now: boundaries, invariants, current limits.
- `docs/history/architecture-decisions.md` — why: one record per design decision.
- `docs/SPEC.md` — product scope and roadmap.
- `docs/DEVELOPMENT.md` — verification commands, CI, and which document owns what.
- `docs/REFERENCES.md` — upstream sources and the Flare pin.

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
