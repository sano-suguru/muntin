# Agent progress

This file is a concise factual handoff between coding sessions. Keep it short enough to read at the start of every session.

## Active milestone
M1 — Flare transport adapter. M1-001 (PR #4), M1-002 (PR #5) merged; M1-003 (real localhost round trip, PR #6) verified, so every M1 feature now has passing evidence. M0 and M0.5 are merged (PRs #1, #2).

## M1-003 result
- `adapters/flare/test_localhost_roundtrip.mojo` (flare env only): parent `HttpServer.bind(SocketAddr.localhost(0))` (ephemeral 127.0.0.1 port), `fork()`; the child serves `MuntinHandler(hello_app())`; the parent sends `GET /hello` with Flare's `HttpClient` (cleartext HTTP/1.1, `Connection: close`, 5 s connect/read timeouts), then `GET /missing`. Asserts 200 `hello`, equality with `TestClient(hello_app()).get("/hello")`, and 404 `Not Found`.
- Readiness: `TcpListener.bind` calls `listen(2)` (backlog 128) before returning, so connections queue before the child enters `serve`; no sleep. Termination: SIGKILL + `waitpid` in `finally`; the child arms a 30 s `alarm(2)` (verified: an orphaned child is gone by 31 s). `check_flare.sh` runs it with output to a file (a pipe would wait on an orphan) and fails if `pgrep -f '^\./build/test_localhost_roundtrip$'` finds a leftover.
- Wire, observed with `curl -i` and the test's client: `HTTP/1.1 200 OK`, `Content-Length: 5`, `Date`, `Connection: keep-alive`, no `Content-Type`; 404 is `HTTP/1.1 404 Not Found`, body `Not Found`. Flare fills the reason phrase when Muntin leaves it unset.
- Lifecycle is fixture-only: no `app.run()`, runtime, or shutdown API; adapter and `src/muntin` unchanged.
- CI `flare` job green on ubuntu24 20260927.320.1 (Ubuntu 24.04.5, x86_64) and macos26 20260907.0351.1 (macOS 26.6.2, arm64); run ID in the PR description.

## M1-002 result
- `adapters/flare/muntin_flare.mojo` (outside `src/`, flare env only): `to_muntin_request`, `to_flare_response`, and `MuntinHandler(Handler)` owning an `App`; `serve` = convert -> `App.handle` -> convert. No routing in the adapter, no M0.5 storage, `src/muntin` unchanged.
- Policy: method and request target (`url`, path + query) verbatim; body copied as lossy UTF-8 `String`; headers/version/peer dropped; response copies status and body bytes, reason unset (Flare's default applies; not yet observed on the wire), no headers.
- `adapters/flare/test_muntin_flare.mojo` 7/7, built `--Werror` and run by `check_flare.sh`, which also checks adapter formatting and that the adapter does not build in the default env.
- `adapters/flare/serve_probe.mojo` (compile-only, built `--Werror` by `check_flare.sh`): `HttpServer.serve(handler^)` accepts an owned `MuntinHandler`. Dropping its `Handler` conformance → `no matching method in call to 'serve'`; passing it without `^` → `cannot be implicitly copied`.
- CI `flare` job (cold `pixi install --locked -e flare`, `cache: false`, then `check_flare.sh`) is green on ubuntu24 20260920.314.1 (Ubuntu 24.04.5, x86_64) and macos26 20260907.0351.1 (macOS 26.6.2, arm64) on PR #5; run IDs live in the PR description, not in committed files. The `verify` job asserts `.pixi/envs/flare` is never installed.

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
- `./scripts/check_flare.sh` → exit 0 (Mojo 1.1.0 (8189361e) in `flare` env; flare 0.11.0 `v0.11.0#59bda50f`; fixture prints `200 hello`; adapter tests 7/7; serve probe builds; localhost round trip 1/1, no leftover process; default env lacks `flare`).
- Round-trip mutations (planted, reverted), each red: client path `/missing`, route registered as `/hell`, handler returns `hi`, client to `port + 1` (bounded `NetworkError`), adapter skips `App.handle` (empty 200, and constant 200 `hello` caught by the 404 check), adapter forces 201, cleanup removed (`check_flare.sh` exit 1: "left a server process behind"). A fresh-context review found no material issues; its suggestions (wire 404 check, `NO_PROXY`, anchored `pgrep`, child error logging) were applied.
- CI on PR #5: `verify` and `flare` jobs success on ubuntu-latest and macos-latest.
- Adapter mutations (planted, reverted), each → `check_flare.sh` exit 1 via failing tests: bypass `App.handle`, fixed path, method forced to GET, request body dropped, status forced to 200, response body replaced, empty 200 Flare response.
- `./scripts/check.sh` → exit 0 (prints `Mojo 1.1.0 (8189361e)`; format ok; boundary ok; package, tests (`--Werror`) and example build ok).
- `./scripts/test.sh` → exit 0 (`tests/test_app.mojo` 6/6, `tests/test_spike_handler_model.mojo` 4/4).
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
- No `app.run()`: the only listening socket is the M1-003 test fixture. Whether `app.run()` belongs to Muntin (DX.md lists it as a target) is undecided; SPEC M1 does not require it.
- Only non-raising `def() -> String` GET handlers; no raw `Request -> Response` handlers, no `app.post`, no extraction.
- Route literal is a compile-time parameter but is only stored as a runtime `String`; no compile-time validation yet.
- Request has no headers; Response has no headers/content type.
- Route lookup is a linear scan; duplicate registrations silently use the first match; matching is exact, so `/hello?x=1` → 404 (no query splitting).
- `muntin.testing` is imported by `main.mojo` only because `app.run()` does not exist; it is not the canonical example.

## Risks for later milestones
- M2: the provisional handler storage relies on `Pointer.unsafe_bitcast` of thin function values; re-run the spike test on every Mojo upgrade. Raising handlers, closures, and non-`Int` path parameters are not prototyped.
- Responses carry no Content-Type on the wire (observed in M1-003); Muntin `Response` has no headers yet.
- `Request.path` receives the raw target including the query, decided by the adapter (and TestClient) rather than core. Core must settle path/query semantics no later than query extraction (M2); DX.md targets `GET /search?query=...`.
- CI: `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19. Current green evidence is ubuntu24; if the flare job breaks after that date, compare `ImageOS`/`ImageVersion` in the `runner image` step before blaming Muntin or Flare.
- The localhost round trip relies on `fork(2)` in a Mojo process (as Flare's own tests do); Windows is out of scope. Its child exits only via SIGKILL or the 30 s alarm, since v0.11.0's `close()`/`drain()` need a second thread.
- The flare CI job rebuilds Flare's C/C++ FFI wrappers from source on every run (no cache, ~1 min).
- M1: v0.11.0's old server spellings (`bind_many`, `serve_tls`, ...) are shims removed in v0.12; use `HttpServer.bind`/`serve`. Flare's `Request` is `Movable` and holds `List[UInt8]` bodies, so the adapter copies into Muntin's `String`-owning types.
- M1: Flare HTTP/3 is unavailable from the conda build (no rustls cdylib); irrelevant unless Muntin needs h3.

## Open blockers
None.

## Next smallest step
M2-001 (after PR #6 merges): deliver one path parameter to a handler as `Int` without manual parsing (`docs/GOALS.md` M2 goal), through both TestClient and the Flare path with the same handler signature.
