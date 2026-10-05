# Agent progress

The current handoff between coding sessions: state, what is easy to get wrong now, the latest evidence and the next step. Detail belongs in the documents it points to; when a new slice lands, the previous slice's description goes. Earlier per-item results, mutation lists and command logs are in [`docs/history/progress-log.md`](docs/history/progress-log.md), which is also what `feature_list.json` means when an earlier item says `AGENT_PROGRESS.md` records or lists something (results, merged PRs, mutation lists, command logs).

## Active milestone

M3 (composition and production ergonomics) is active. M0, M0.5, M1 and M2 are complete (M2 closed by M2-016, PR #24; contract in `docs/SPEC.md`, "M2 completion contract"). Every feature in `feature_list.json` up to M3-014 has `passes: true` (M3-014: PR #43). M3-015 (its slice) is `passes: false`.

M3 so far:

| Area | Decision | Production |
|---|---|---|
| application state | M3-001 (`State[S]` bound at registration, PR #25); M3-004 (sealed `_Shared` storage, PR #27) | M3-003 stateful `get` (PR #26), M3-006 stateful `post` (PR #30), M3-007 stateful raw (PR #31) |
| headers | M3-002 (`muntin.Headers`, PR #28) | M3-005 (PR #29) |
| JSON | M3-008 (`Json[T]` over `FromJson`/`ToJson`, PR #32) | M3-009 (PR #36) |
| `TestClient` request headers | M3-010 (PR #39) | M3-011 (PR #40) |
| typed header access | M3-012 (`WithHeaders[B]` body carrier on `post`, PR #41) | M3-013 (PR #42) |
| registration structure | M3-014 (generic-arity slots on `get`/`post`; reopens M2 in M3-015) | M3-015 (next) |

## Current increment

M3-014 (decision, PR #43; `src/muntin` and `adapters/` unchanged): selected C4r, one overload per request-slot arity on each method (stateless and stateful families; the stateful one keeps a fixed leading `State[S]`), every request-derived parameter a generic slot `var A` classified at compile time, the result type generic. Spellings, binding, request steps and storage stay; M3-015 reopens M2 for the overload declarations, the diagnostics of rejected calls (a shape that selects an overload reports a Muntin rule as `constraint failed` instead of candidate notes), an owned `Int` route value and typed `-> StaticString` function values becoming accepted (result types for plain `def` handlers stay as production's through a `where` clause on every overload, because generic `==` cannot tell `StaticString` from other immutable-origin slices), and typed function values with a borrowed `Int` route value (a leading `State[S]` keeps its spelling; borrowed bodies and `Request`s already need `var`) needing `var`. Raw `String` is a route value, never a body. The arity overloads give structural headroom through slot arity 4, with full candidate notes only through slot arity 3 (an accepted cost); the ceiling remains. Retained evidence: `tests/registration_spike.mojo` with `tests/test_spike_registration.mojo`, `tests/registration_fail`, `tests/registration_known_gaps`. Record: `docs/history/architecture-decisions.md`, "Registration structure decision (M3-014)".

## Easy to get wrong now

The current contract is `docs/ARCHITECTURE.md`, "Current architecture". Points a new session tends to miss:

- Typed handlers read headers only on `post`, through a `WithHeaders[B]` body. `WithHeaders` is a body-slot type but not a `FromBody` (the accepted cost): generic code bounded by `B: FromBody` does not take it. Header access on typed `get` handlers stays a target: in today's overload set every measured `get` shape drops candidate notes or changes an M2 signature. M3-014 decided the structure that admits it (a `Headers` slot or the carrier, no overload up to arity 2) after M3-015. The JSON `Content-Type` check is a separate verdict for `Json[T]` bodies only, not header extraction.
- `TestClient` sends header fields only through `headers=`: `client.post(target, body)` to a JSON body route is still 415, and `tests/test_json.mojo` pins that on purpose. The client never adds a field (no automatic `Content-Type`, no per-client defaults); a test that needs the field sends it.
- `get` and `post` have ten overloads each, Mojo 1.1.0's ten-note diagnostic cap; an eleventh must measure its diagnostics first. The cap counts per method name, so a new method is its own set (M3-014). M3-015 replaces the families with arity overloads; until it merges, production is unchanged.
- `rebind_var` accepts a different struct with the same layout (`tests/registration_known_gaps`): a generic slot is rebound only behind a type-equality assert (exact for origin-free types; generic `==` ignores which origin a slice has, keeping only mutability), and `check_unsafe.sh` does not check `rebind_var` yet (M3-015 adds a dedicated check).
- M2 is closed: a new item adds to the M2 contract; changing an M2 signature or the 400/404/500 boundary reopens M2 (`docs/ARCHITECTURE.md`, "When M2 reopens").
- `App.handle` is never called concurrently today; a concurrent backend or a `Copyable` `App` reopens the JSON cap and interior mutability in `State` values.
- `main` needs a pull request, up to date, with `ci-ok`; a change touching only `docs/` or `*.md` skips `verify` and `flare`.
Blockers: none.

## Temporary watch

Time-bound operational notes. Each says when to delete it.

- `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19. If the `flare` job breaks after that date, compare `ImageOS`/`ImageVersion` in the `runner image` step before blaming Muntin or Flare. Delete this once a `flare` job has passed on Ubuntu 26.

## Latest verification evidence

M3-014: `check.sh` (with the new fixtures), `test.sh` (the spike included), `check_flare.sh` and `git diff --check` pass on the branch; `git diff main -- src adapters` is empty. The candidates were measured on scratch copies against `main`'s fixtures; full evidence: the decision record.

## Next step

After PR #43 passes CI and review and merges: M3-015, exactly the record's "Next production slice (M3-015)". The M2 reopen is decided by M3-014's record; undoing it needs a new decision.

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
