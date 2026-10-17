# Implemented M0 layout (Mojo 1.1.0)

> **Superseded** by [M3-015 production](m3-015-registration-on-generic-arity-slots-in-production.md), [M3-040](m3-040-binary-request-and-response-bodies-decision.md) and [M3-063](m3-063-request-context-decision.md). Now described in [ARCHITECTURE, "Modules and public surface"](../../ARCHITECTURE.md#modules-and-public-surface), [ARCHITECTURE, "Backend seam"](../../ARCHITECTURE.md#backend-seam) and [ARCHITECTURE, "Current architecture"](../../ARCHITECTURE.md#current-architecture).
> What changed:
> - [M3-015 production](m3-015-registration-on-generic-arity-slots-in-production.md): app.mojo's per-shape get/post overloads became six (now eight) generic-arity overloads per method.
> - [M3-040](m3-040-binary-request-and-response-bodies-decision.md): Request/Response no longer own String bodies.
> - [M3-063](m3-063-request-context-decision.md): the seam is no longer a single concrete method: an owning App.handle overload was added (M3-064).

```text
src/muntin/__init__.mojo   public exports: App, FromBody, Request, Response, ToErrorResponse, ToResponse
src/muntin/http.mojo       Request(method, target, body) -> path, query, body; Response(status, body); ToResponse (M2-008), ToErrorResponse (M2-013)
src/muntin/body.mojo       FromBody: the request-body conversion trait an application type conforms to (M2-006)
src/muntin/app.mojo        App: route table; get[route](handler) for (), (Int) and raw (Request); post[route](handler) for (B), (Int, B) and raw (Request); handle(Request) -> Response (shapes as of M2-015: "M2 closure (M2-016)")
src/muntin/_handler_storage.mojo  private: _Erased typed handler box; the only module with unsafe operations (M2-004)
src/muntin/testing.mojo    TestClient: in-memory backend (get, post), imports only muntin modules
```

The backend seam is the single concrete method `App.handle(self, request: Request) -> Response`. A backend converts its input into a Muntin `Request`, calls `handle`, and converts the returned `Response` back. `TestClient` does exactly that without a socket; the Flare adapter (M1-002) does the same and does not route on its own. There is deliberately no backend trait yet (A7): one implementation exists, and the trait can be extracted when a second backend arrives.

Requests and responses own their data (`String` fields, copied in). No backend buffer lifetimes appear in the public types. `TestClient` borrows the `App` immutably through an origin parameter, so `App.handle` takes `self` read-only and dispatch cannot mutate routing state.

`scripts/check_boundaries.sh` enforces A2 mechanically: it fails if any module under `src/muntin` imports or mentions Flare or socket modules. `scripts/check_unsafe.sh` confines unsafe pointer/ownership operations to `src/muntin/_handler_storage.mojo` (M2-004, "Production implementation" below). `scripts/check.sh` runs both.

The Flare adapter (M1-002) lives outside the boundary-checked core path, in `adapters/flare/muntin_flare.mojo`, and imports only Flare and Muntin's public `App`/`Request`/`Response`; nothing under `src/` imports it.

Flare (M1-001) is a dependency of the separate `flare` pixi environment only (`[feature.flare]` in `pixi.toml`, pinned to the released tag `v0.11.0`; `pixi.lock` records commit `59bda50f`). The default environment, which `check.sh` and `test.sh` use to build and test `src/muntin`, does not have Flare on its module path. `compat/flare/flare_smoke.mojo` is a Flare-only compatibility fixture (no Muntin import); `scripts/check_flare.sh` builds and runs it in the `flare` environment and fails if the same fixture builds in the default environment.
