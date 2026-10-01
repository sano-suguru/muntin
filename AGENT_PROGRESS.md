# Agent progress

This file is a concise factual handoff between coding sessions. Keep it short enough to read at the start of every session.

## Active milestone
M0 — architecture bootstrap (all M0 features verified; see `feature_list.json`).

## Current state
- Toolchain: **Mojo 1.1.0 (8189361e)** via pixi 0.81.0, pinned by `pixi.lock`. Environment was not reinstalled or reconfigured; `pixi.toml` only gained `check`/`test` tasks pointing at the scripts.
- Core: `src/muntin/{__init__,http,app,testing}.mojo`. Public exports `App`, `Request`, `Response`; in-memory `muntin.testing.TestClient`.
- Seam: `App.handle(self, Request) -> Response`. `TestClient.get` builds a `Request` and calls it; no socket, no Flare.
- Routing: exact match on method + path; unmatched → 404 `Not Found`.
- `main.mojo` is the Hello World example (driven via TestClient because `app.run()` is M1).
- Placeholder `greet`/`core.mojo`/`tests/test_core.mojo` removed.
- Docs moved to the locations every document already referenced: `docs/{DX,ARCHITECTURE,SPEC,DEVELOPMENT,CLAUDE_CODE,GOALS,REFERENCES}.md`; path-scoped rules to `.claude/rules/{mojo,public-api}.md` (they carry `paths:` frontmatter).

## Last verified commands (all from repo root)
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
- M2: typed handlers such as `get_user(id: Int) -> User` need heterogeneous route storage (type erasure or a trampoline into a uniform `Request -> Response` entry). Not yet shown to be expressible in Mojo 1.1.0 with a runtime handler argument; spike this before freezing `app.get[path](handler)` for typed handlers.
- M1: `check_boundaries.sh` scans all of `src/muntin`, so a Flare adapter at `src/muntin/adapters/flare` would fail it. Place the adapter outside `src/muntin` or scope the check deliberately.
- M1: Request/Response have no headers or content type; the adapter must choose defaults.

## Open blockers
None.

## Next smallest step
M0.5 typed-handler feasibility spike, before Flare: can one app store `def() -> String`, `def(Int) -> User` and `def(Request) -> Response` handlers behind `app.get["/users/{id}"](get_user)`? The answer can change the public API, so M1 waits. Defined and executed in PR #2 (`docs/SPEC.md` M0.5, `feature_list.json` M0.5-001..003).
