# Muntin

Muntin is an experimental, typed web application framework for Mojo.

The project is deliberately focused on the layer above networking: application routing, typed extraction, validation, serialization, middleware, errors, observability, testing, and developer experience. Networking implementations live behind a narrow adapter boundary.

Muntin is pre-alpha. The repository starts by proving the architecture and public API direction before attempting a production feature set.

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
  backend         (M1+)
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

## Milestones

### M0 — architecture bootstrap

Prove that Muntin owns its application model and can dispatch requests through an in-memory backend with no Flare dependency.

### M1 — Flare adapter

Connect the existing Muntin application seam to a pinned Flare release and prove a real localhost HTTP round trip without leaking Flare types into application code.

### M2 — typed application API

Complete (M2-016). Typed routes, `Int` path/query extraction, typed request bodies, response conversion, an application-error model and a raw `Request -> Response` escape hatch, all independent of the transport. `docs/SPEC.md` ("M2 completion contract") lists what M2 guarantees and what it leaves out.

### M3 — composition and production ergonomics

Application state (decided in M3-001 as a `State[S]` handler parameter bound at registration; production for `get` since M3-003, for `post` since M3-006, and for raw `Request -> Response` handlers on both since M3-007), headers (decided in M3-002; request and response headers production since M3-005, typed extraction and default headers not), codecs and schema/OpenAPI output, more route values and methods, middleware, observability, streaming, lifecycle (`app.run()`) and production hardening. Each is decided before it is built, and only once the application model earns the abstraction.

## Repository guide

- `docs/DX.md` — canonical public API and developer-experience target.
- `docs/ARCHITECTURE.md` — dependency boundaries and invariants.
- `docs/SPEC.md` — milestone scope and acceptance criteria.
- `docs/DEVELOPMENT.md` — engineering and verification loop.
- `docs/CLAUDE_CODE.md` — Claude Code `/goal` and model/harness guidance.
- `docs/GOALS.md` — ready-to-paste `/goal` conditions.
- `docs/REFERENCES.md` — authoritative sources behind volatile assumptions.
- `feature_list.json` — machine-readable completion state.
- `AGENT_PROGRESS.md` — concise handoff between coding sessions.

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

## Current status

M0, M1 and M2 are complete; M3 is active. Status lives in `feature_list.json` and `AGENT_PROGRESS.md`. Nothing is considered verified until the checks there have executable evidence. `docs/DX.md` separates syntax proven on the current toolchain from target syntax.
