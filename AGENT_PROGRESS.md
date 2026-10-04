# Agent progress

The current handoff between coding sessions: state, what is easy to get wrong now, the latest evidence and the next step. Detail belongs in the documents it points to; when a new slice lands, the previous slice's description goes. Earlier per-item results, mutation lists and command logs are in [`docs/history/progress-log.md`](docs/history/progress-log.md), which is also what `feature_list.json` means when an earlier item says `AGENT_PROGRESS.md` records or lists something (results, merged PRs, mutation lists, command logs).

## Active milestone

M3 (composition and production ergonomics) is active. M0, M0.5, M1 and M2 are complete (M2 closed by M2-016, PR #24; contract in `docs/SPEC.md`, "M2 completion contract"). Every feature in `feature_list.json` up to M3-011 has `passes: true`; M3-012 (decision, PR #41) passes after its CI, and M3-013 is next.

M3 so far:

| Area | Decision | Production |
|---|---|---|
| application state | M3-001 (`State[S]` bound at registration, PR #25); M3-004 (sealed `_Shared` storage, PR #27) | M3-003 stateful `get` (PR #26), M3-006 stateful `post` (PR #30), M3-007 stateful raw (PR #31) |
| headers | M3-002 (`muntin.Headers`, PR #28) | M3-005 (PR #29) |
| JSON | M3-008 (`Json[T]` over `FromJson`/`ToJson`, PR #32) | M3-009 (PR #36) |
| `TestClient` request headers | M3-010 (PR #39) | M3-011 (PR #40) |
| typed header access | M3-012 (`WithHeaders[B]` body carrier on `post`, PR #41) | M3-013 (next) |

## Current increment

M3-012 (decision only; PR #41): typed `post` handlers will read request header fields through a Muntin body carrier, `WithHeaders[B]`, in the existing body slot, with no overload and no injected slot; typed `get` handlers stay on the raw `get`. `src/muntin` and `adapters/` are unchanged. `tests/header_access_spike.mojo` (`CarrierApp`, `SpikeWithHeaders`) is decision evidence, not production. Record: `docs/history/architecture-decisions.md`, "Typed header access decision (M3-012)".

## Easy to get wrong now

The current contract is `docs/ARCHITECTURE.md`, "Current architecture". Points a new session tends to miss:

- Typed handlers cannot read headers until M3-013 lands, and then only on `post` (`WithHeaders[B]`); a typed header shape on `get` is rejected on Mojo 1.1.0 (note cap), not merely deferred. The JSON `Content-Type` check is a separate verdict for `Json[T]` bodies only, not header extraction.
- `TestClient` sends header fields only through `headers=`: `client.post(target, body)` to a JSON body route is still 415, and `tests/test_json.mojo` pins that on purpose. The client never adds a field (no automatic `Content-Type`, no per-client defaults); a test that needs the field sends it.
- `get` and `post` have ten overloads each, Mojo 1.1.0's ten-note diagnostic cap; an eleventh must measure its diagnostics first.
- M2 is closed: a new item adds to the M2 contract; changing an M2 signature or the 400/404/500 boundary reopens M2 (`docs/ARCHITECTURE.md`, "When M2 reopens").
- `App.handle` is never called concurrently today; a concurrent backend or a `Copyable` `App` reopens the JSON cap and interior mutability in `State` values.
- `main` needs a pull request, up to date, with `ci-ok`; a change touching only `docs/` or `*.md` skips `verify` and `flare`.
Blockers: none.

## Temporary watch

Time-bound operational notes. Each says when to delete it.

- `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19. If the `flare` job breaks after that date, compare `ImageOS`/`ImageVersion` in the `runner image` step before blaming Muntin or Flare. Delete this once a `flare` job has passed on Ubuntu 26.

## Latest verification evidence

M3-012: the local canonical checks pass, and `src/muntin` and `adapters/` are unchanged. Full evidence: the decision record.

## Next step

M3-013, exactly the record's "Next production slice (M3-013)" (`WithHeaders[B]` in a new module, the carrier branch in `src/muntin/app.mojo`, `tests/test_with_headers.mojo`, `tests/with_headers_api_fail`, one loopback route, the M3-012 spike and its carrier fixtures deleted). Acceptance: `feature_list.json` M3-013.

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
