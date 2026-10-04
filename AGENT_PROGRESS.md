# Agent progress

The current handoff between coding sessions: state, what is easy to get wrong now, the latest evidence and the next step. Detail belongs in the documents it points to; when a new slice lands, the previous slice's description goes. Earlier per-item results, mutation lists and command logs are in [`docs/history/progress-log.md`](docs/history/progress-log.md), which is also what `feature_list.json` means when an earlier item says `AGENT_PROGRESS.md` records or lists something (results, merged PRs, mutation lists, command logs).

## Active milestone

M3 (composition and production ergonomics) is active. M0, M0.5, M1 and M2 are complete (M2 closed by M2-016, PR #24; contract in `docs/SPEC.md`, "M2 completion contract"). Every feature in `feature_list.json` up to M3-009 has `passes: true`; M3-010 (decision) and M3-011 (its production slice) do not yet.

M3 so far (merged unless marked):

| Area | Decision | Production |
|---|---|---|
| application state | M3-001 (`State[S]` bound at registration, PR #25); M3-004 (sealed `_Shared` storage, PR #27) | M3-003 stateful `get` (PR #26), M3-006 stateful `post` (PR #30), M3-007 stateful raw (PR #31) |
| headers | M3-002 (`muntin.Headers`, PR #28) | M3-005 (PR #29) |
| JSON | M3-008 (`Json[T]` over `FromJson`/`ToJson`, PR #32) | M3-009 (PR #36) |
| `TestClient` request headers | M3-010 (not merged) | M3-011 (next) |

## Latest verified increment

M3-010 (decision only; not merged): `TestClient.get` and `.post` gain a last, defaulted `var headers: Headers = Headers()` argument, moved into the `Request` they build, and nothing else. `src/muntin` and `adapters/` are unchanged. Record: `docs/history/architecture-decisions.md`, "TestClient request headers decision (M3-010)". `passes` stays `false` until CI on its pull request passes.

## Easy to get wrong now

The current contract is `docs/ARCHITECTURE.md`, "Current architecture". Points a new session tends to miss:

- Typed handlers cannot read headers (typed header extraction is not implemented). The JSON `Content-Type` check is a separate verdict for `Json[T]` bodies only, not header extraction.
- `TestClient` sends no header fields until M3-011 lands, so `TestClient.post` to a JSON body route is 415; JSON body tests call `app.handle(Request(..., headers^))`. `SpikeClient` in `tests/testclient_headers_spike.mojo` is decision evidence, not the production client.
- `get` and `post` have ten overloads each, Mojo 1.1.0's ten-note diagnostic cap; an eleventh must measure its diagnostics first.
- M2 is closed: a new item adds to the M2 contract; changing an M2 signature or the 400/404/500 boundary reopens M2 (`docs/ARCHITECTURE.md`, "When M2 reopens").
- `App.handle` is never called concurrently today; a concurrent backend or a `Copyable` `App` reopens the JSON cap and interior mutability in `State` values.
- `main` needs a pull request, up to date, with `ci-ok`; a change touching only `docs/` or `*.md` skips `verify` and `flare`.
Blockers: none.

## Temporary watch

Time-bound operational notes. Each says when to delete it.

- `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19. If the `flare` job breaks after that date, compare `ImageOS`/`ImageVersion` in the `runner image` step before blaming Muntin or Flare. Delete this once a `flare` job has passed on Ubuntu 26.

## Latest verification evidence

M3-010: `./scripts/check.sh`, `./scripts/test.sh`, `./scripts/check_flare.sh` and `git diff --check` exit 0; `git diff main -- src adapters` is empty. Spike 9/9, `tests/testclient_headers_fail` 3, scratch copies of `src/muntin` pass the 273 existing tests unchanged, 5 spike mutations red (details in the record).

## Next step

After M3-010 merges: M3-011, exactly the record's "Next production slice (M3-011)" (two signatures in `src/muntin/testing.mojo`, `tests/test_testclient_headers.mojo`, `tests/testclient_headers_api_fail`, DX section 4's JSON example through the client). Acceptance: `feature_list.json` M3-011.

## Where things are

| Need | Document |
|---|---|
| current public API, runnable examples, current limits, targets | `docs/DX.md` |
| current architecture, invariants, revisit index, decision record stubs | `docs/ARCHITECTURE.md` |
| decision records (reasons, evidence, rejected candidates, revisit conditions) | `docs/history/architecture-decisions.md` |
| milestone scope, M2 contract, M3 item index and candidates | `docs/SPEC.md` (item scope paragraphs: `docs/history/spec-items.md`) |
| acceptance, pass state, evidence | `feature_list.json` |
| verification loop and update rules | `docs/DEVELOPMENT.md` |
| earlier results, mutation lists, command logs | `docs/history/progress-log.md` |
