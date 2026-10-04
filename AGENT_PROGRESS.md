# Agent progress

The current handoff between coding sessions: state, decisions in force, constraints, the latest evidence and the next step. Keep it short; detail belongs in the documents it points to. Earlier per-item results, mutation lists and command logs are in [`docs/history/progress-log.md`](docs/history/progress-log.md), which is also what `feature_list.json` means when an earlier item says `AGENT_PROGRESS.md` records or lists something (results, merged PRs, mutation lists, command logs).

## Active milestone

M3 (composition and production ergonomics) is active. M0, M0.5, M1 and M2 are complete (M2 closed by M2-016, PR #24; contract in `docs/SPEC.md`, "M2 completion contract"). Every feature in `feature_list.json`, M3-001 to M3-009 included, has `passes: true`.

M3 so far, each merged:

| Area | Decision | Production |
|---|---|---|
| application state | M3-001 (`State[S]` bound at registration, PR #25); M3-004 (sealed `_Shared` storage, PR #27) | M3-003 stateful `get` (PR #26), M3-006 stateful `post` (PR #30), M3-007 stateful raw (PR #31) |
| headers | M3-002 (`muntin.Headers`, PR #28) | M3-005 (PR #29) |
| JSON | M3-008 (`Json[T]` over `FromJson`/`ToJson`, PR #32) | M3-009 (PR #36) |

## Latest completed slice

M3-009, JSON in production (merged PR #36; recorded as merged in PR #37). `muntin` exports `Json`, `FromJson`, `ToJson`, `JsonValue` and `JsonWriter`; `Json[T]` registers on the existing body and result overloads (no overload or shape added). On a JSON body route the order is 404, query 400, route-value 400, 415 (`Content-Type` not exactly one `application/json`), 413 (body over 1 MiB), JSON 400, handler. A JSON result is 200 with exactly `Content-Type: application/json`. Current behavior: `docs/ARCHITECTURE.md`, "JSON"; decision and evidence: the "JSON codec decision (M3-008)" and "JSON in production (M3-009)" records; acceptance and evidence: `feature_list.json` M3-009.

## Decisions in force

The current contract is `docs/ARCHITECTURE.md`, "Current architecture"; the decision index there links each record. In short:

- `App.handle(Request) -> Response` is the only backend seam; `TestClient` and the Flare adapter both use it, and no backend type reaches application code. No backend trait until a second backend exists.
- `App.get` and `App.post` have ten overloads each: `def()`/`def(Int)` on `get`, `def(B)`/`def(Int, B)` with `B: FromBody` on `post`, raw `def(Request) -> Response` on both, and a stateful twin of each with `State[S]` first, registered as `(handler, state)`. Binding is positional; one injected slot.
- Errors: request failures are 400 before the handler, no match is 404, a handler raise is `ToErrorResponse` when its declared type opts in, else the fixed 500 with the error dropped unread.
- `State` storage keeps the M3-004 guarantee; toolchain-wide primitives are outside it and pinned in `tests/toolchain_soundness_gaps`.
- Headers: raw handlers read and write fields; typed handlers read none (typed header extraction is not implemented). The JSON `Content-Type` check is a separate verdict for `Json[T]` bodies only. `Response.text` and `String` results add no field; `Json[T]` results add `Content-Type: application/json`.
- Unsafe operations live only in `src/muntin/_handler_storage.mojo` (`check_unsafe.sh`).
- Toolchain: Mojo 1.1.0 (8189361e) via pixi 0.81.0, pinned by `pixi.lock`; Flare v0.11.0 only in the `flare` environment.

## Constraints and blockers

- Blockers: none.
- `get` and `post` are at Mojo 1.1.0's ten-note diagnostic cap; a slice that adds an eleventh overload must measure its diagnostics first.
- `TestClient` sends no header fields, so `TestClient.post` to a JSON body route is 415; JSON body tests use `app.handle(Request(..., headers^))`.
- `App.handle` is never called concurrently today; a concurrent backend or a `Copyable` `App` reopens the JSON cap and interior mutability in `State` values.
- `main` requires a pull request that is up to date and the `ci-ok` check; a change touching only `docs/` or `*.md` files skips the `verify` and `flare` jobs (`docs/DEVELOPMENT.md`, section 6).
- CI: `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19. If the `flare` job breaks after that date, compare `ImageOS`/`ImageVersion` in the `runner image` step before blaming Muntin or Flare.
- Other limits and operational risks: `docs/ARCHITECTURE.md`, "Other current limits and operational risks".

## Latest verification evidence

- M3-009 (PR #36): `./scripts/check.sh`, `./scripts/test.sh`, `./scripts/check_flare.sh` and `git diff --check` exit 0; CI `verify` and `flare` pass on ubuntu-latest and macos-latest. Counts and mutations: `feature_list.json` M3-009.
- Documentation reorganization after M3-009 (no code change): `feature_list.json` byte-identical to the previous commit; no change under `src/`, `adapters/`, `tests/`, `scripts/`, `compat/`, `.github/` or the pixi files; every moved section contained verbatim in `docs/history/`; internal links, anchors and `docs/ARCHITECTURE.md "<title>"` citations resolve; `git diff --check` exit 0; `./scripts/check.sh` exit 0 (267 fixtures) and `./scripts/test.sh` exit 0 (27 suites, 273 tests, none failed or skipped) on the unchanged code. `check_flare.sh` was not run (no adapter or code change).

## Next step

No next item is chosen in the repository. Candidates are `docs/SPEC.md`, M3, "Remaining candidates"; the nearest follow-up the JSON records name is a way for `TestClient` to send header fields (`docs/history/architecture-decisions.md`, "JSON codec decision (M3-008)", revisit conditions). Start any next item as its own decision-first entry in `feature_list.json` and `docs/SPEC.md`.

## Where things are

| Need | Document |
|---|---|
| current public API, runnable examples, current limits, targets | `docs/DX.md` |
| current architecture, invariants, decision and revisit indexes | `docs/ARCHITECTURE.md` |
| decision records (reasons, evidence, rejected candidates, revisit conditions) | `docs/history/architecture-decisions.md` |
| milestone scope, M2 contract, M3 item index and candidates | `docs/SPEC.md` (item scope paragraphs: `docs/history/spec-items.md`) |
| acceptance, pass state, evidence | `feature_list.json` |
| verification loop and update rules | `docs/DEVELOPMENT.md` |
| earlier results, mutation lists, command logs | `docs/history/progress-log.md` |
