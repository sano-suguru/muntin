# Agent progress

This file is a concise factual handoff between coding sessions. Keep it short enough to read at the start of every session.

## Active milestone
M1 — Flare transport adapter. M1-001 (Flare pin) verified; M1-002/M1-003 not started. M0 and M0.5 are merged (PRs #1, #2).

## M1-001 result
- Flare **v0.11.0** (commit `59bda50f46853f7351eef12f1737f7fb2287de71`, MIT) is the only release declaring `mojo >=1.1.0`. v0.10.0 fails `pixi lock` under pixi 0.81.0 (its `pixi-build-rattler-build ==0.3.13` pin needs build API 4) and declares `mojo <1.1.0`; v0.9.0/v0.8.1 pin `1.0.0b2`.
- Pinned as a pixi-build git source dependency in a separate `flare` environment (`[feature.flare]`, `preview = ["pixi-build"]`). The default environment is unchanged in `pixi.lock` and cannot import Flare.
- `compat/flare/flare_smoke.mojo` is a Flare-only fixture (no Muntin import, no socket). `scripts/check_flare.sh` asserts Mojo 1.1.0 in the `flare` env, builds the fixture with `--Werror`, runs it (`200 hello`), and asserts the default env fails with `unable to locate module 'flare'`.

## M0.5 result
- The runtime handler value syntax `app.get["/users/{id}"](get_user)` works: `tests/test_spike_handler_model.mojo` dispatches `() -> String`, `(Int) -> User`, `(Request) -> Response` from one app through `handle(Request)`. `src/muntin` unchanged.
- Feasibility, not adoption: a prototype storing the function pointer as `Int` bits + same-type trampoline works, but it is unsafe and provisional until M2. Closures and `rebind` fail (diagnostics in `docs/DX.md`). The compile-time handler parameter works but worsens the public syntax.
- Return conversion: a Muntin-owned conversion from typed return values to `Response` is the direction; the `ToResponse` trait and its `__extension` conformances are provisional.
- Route/handler arity mismatch fails at compile time. Parameter names cannot be reflected, so binding is positional.

## Current state
- Toolchain: **Mojo 1.1.0 (8189361e)** via pixi 0.81.0, pinned by `pixi.lock`. The default environment is unchanged since M0; `pixi.toml` adds `check`/`test`/`check-flare` tasks and the separate `flare` environment (M1-001).
- Core: `src/muntin/{__init__,http,app,testing}.mojo`. Public exports `App`, `Request`, `Response`; in-memory `muntin.testing.TestClient`.
- Seam: `App.handle(self, Request) -> Response`. `TestClient.get` builds a `Request` and calls it; no socket, no Flare.
- Routing: exact match on method + path; unmatched → 404 `Not Found`.
- `main.mojo` is the Hello World example (driven via TestClient because `app.run()` is M1).
- Placeholder `greet`/`core.mojo`/`tests/test_core.mojo` removed.
- Docs moved to the locations every document already referenced: `docs/{DX,ARCHITECTURE,SPEC,DEVELOPMENT,CLAUDE_CODE,GOALS,REFERENCES}.md`; path-scoped rules to `.claude/rules/{mojo,public-api}.md` (they carry `paths:` frontmatter).

## Last verified commands (all from repo root)
- `./scripts/check_flare.sh` → exit 0 (Mojo 1.1.0 (8189361e) in `flare` env; flare 0.11.0 `v0.11.0#59bda50f`; build `--Werror` ok; prints `200 hello`; default env lacks `flare`).
- `./scripts/check.sh` → exit 0 (prints `Mojo 1.1.0 (8189361e)`; format ok; boundary ok; package, tests (`--Werror`) and example build ok).
- `./scripts/test.sh` → exit 0 (`tests/test_app.mojo`: 6 tests run, 6 passed).
- `./build/muntin` → prints `200 hello`.
- `git add -A && git diff --cached --check` → exit 0 (plain `git diff --check` is vacuous for untracked files).
- Negative evidence (planted, then reverted): type error in `http.mojo` → check.sh exit 1 at "build package"; `from flare.http import ...` in `app.mojo` → check.sh exit 1 at "architecture boundary"; misformatted function → check.sh exit 1 at "format"; router changed to `if True:` → test.sh exit 1 (3 tests fail); test file whose `main` never runs the suite → test.sh exit 1; `muntin_flare_adapter` identifier in core → check.sh exit 1; unused variable in a test → check.sh exit 1 at "build tests" (`--Werror`).
- Fresh-context review (general-purpose subagent, read-only): no Flare leakage, TestClient uses `App.handle`, seam narrow, its own mutation tests all caught. Its findings on the boundary grep (`\b` missed `_flare_`), tests not built with `--Werror`, and vacuous test files were fixed above.

## Decisions in force
- Muntin owns `App`/`Request`/`Response`; backends call `App.handle`. No backend trait until a second backend exists (A7).
- Handlers are stored as `def() thin -> String` because `def() -> String` is a trait in Mojo 1.1.0 (repro and diagnostic in `docs/DX.md`). Users still write plain `def hello() -> String`.
- `TestClient[origin: Origin[mut=False]]` borrows the app via `Pointer`, so `TestClient(app)` matches DX without copying.
- Request/Response own `String` data; no backend buffer lifetimes in public types.
- `check.sh` asserts the `Mojo 1.1.0` prefix; upgrading Mojo is a deliberate change that must update the script and docs.

## Remaining limitations
- No `app.run()`, no network backend (M1).
- Only non-raising `def() -> String` GET handlers; no raw `Request -> Response` handlers, no `app.post`, no extraction.
- Route literal is a compile-time parameter but is only stored as a runtime `String`; no compile-time validation yet.
- Request has no headers; Response has no headers/content type.
- Route lookup is a linear scan; duplicate registrations silently use the first match; matching is exact, so `/hello?x=1` → 404 (no query splitting).
- `muntin.testing` is imported by `main.mojo` only because `app.run()` does not exist; it is not the canonical example.

## Risks for later milestones
- M2: the provisional handler storage relies on `Pointer.unsafe_bitcast` of thin function values; re-run the spike test on every Mojo upgrade. Raising handlers, closures, and non-`Int` path parameters are not prototyped.
- M1: `check_boundaries.sh` scans all of `src/muntin`, so a Flare adapter at `src/muntin/adapters/flare` would fail it. Place the adapter outside `src/muntin` or scope the check deliberately.
- M1: Request/Response have no headers or content type; the adapter must choose defaults.
- M1: `check_flare.sh` is not in CI. The `flare` env compiles C/C++ FFI wrappers via pixi-build on install; verified only on osx-arm64. linux-64 is locked but its install/build is unverified.
- M1: v0.11.0's old server spellings (`bind_many`, `serve_tls`, ...) are shims removed in v0.12; use `HttpServer.bind`/`serve`. Flare's `Request` is `Movable` and holds `List[UInt8]` bodies, so the adapter copies into Muntin's `String`-owning types.
- M1: Flare HTTP/3 is unavailable from the conda build (no rustls cdylib); irrelevant unless Muntin needs h3.

## Open blockers
None.

## Next smallest step
M1-002: a Flare adapter outside `src/muntin` (built only in the `flare` env) that converts a Flare `Request` to a Muntin `Request`, calls `App.handle`, and converts the `Response` back, with adapter contract tests that need no socket. It must not use the provisional M0.5 handler storage. Decide whether `check_flare.sh` joins CI at the same time.
