# Agent progress

The current handoff between coding sessions: state, what is easy to get wrong now, the latest evidence and the next step. Detail belongs in the documents it points to; when a new slice lands, the previous slice's description goes. Earlier per-item results, mutation lists and command logs are in [`docs/history/progress-log.md`](docs/history/progress-log.md), which is also what `feature_list.json` means when an earlier item says `AGENT_PROGRESS.md` records or lists something (results, merged PRs, mutation lists, command logs).

## Active milestone

M3 (composition and production ergonomics) is active. M0, M0.5, M1 and M2 are complete (M2 closed by M2-016, PR #24; contract in `docs/SPEC.md`, "M2 completion contract"). Every feature in `feature_list.json` up to M3-014 has `passes: true` (M3-014: PR #43). M3-015 (PR #44) is `passes: false` again until its decision amendment passes review and CI.

M3 so far:

| Area | Decision | Production |
|---|---|---|
| application state | M3-001 (`State[S]` bound at registration, PR #25); M3-004 (sealed `_Shared` storage, PR #27) | M3-003 stateful `get` (PR #26), M3-006 stateful `post` (PR #30), M3-007 stateful raw (PR #31) |
| headers | M3-002 (`muntin.Headers`, PR #28) | M3-005 (PR #29) |
| JSON | M3-008 (`Json[T]` over `FromJson`/`ToJson`, PR #32) | M3-009 (PR #36) |
| `TestClient` request headers | M3-010 (PR #39) | M3-011 (PR #40) |
| typed header access | M3-012 (`WithHeaders[B]` body carrier on `post`, PR #41) | M3-013 (PR #42) |
| registration structure | M3-014 (generic-arity slots on `get`/`post`, PR #43) | M3-015 (PR #44, in review; reopens M2) |

## Current increment

M3-015 (production, the M3-014 slice plus one decision amendment): `get` and `post` have six overloads each, one per request-slot arity (0 to 2), stateless and stateful; every slot is `var A` classified from its type (`Int` route value, `FromBody` or carrier body, `Request`), and `R` is accepted only through `where (R == String or R == StaticString or conforms_to(R, ToResponse))`. One ordered rule function (`_rule`) feeds the rule asserts (`_check`) and the guard (`_admits`) of the adapter's instantiation, whose `else` aborts at registration. Six adapters over `_slot` and `_respond` replace the ten hand adapters; the request order is unchanged. The one `rebind_var` is in `_as`, after `comptime assert A == T`, enforced by `check_unsafe.sh`. M2 reopened for M3-014's three edges (`var id: Int` route values and typed `-> StaticString` values register, typed values with a borrowed `Int` do not) and a fourth edge, generic forwarding, accepted by "Registration structure amendment: generic forwarding (M3-015)" after the PR review found the slice wider than M3-014 decided. Every existing constraint text is kept; 45 fixtures are re-pinned (old and new texts in the record), `body_fail/post_owned_int_and_body` is deleted, and the M3-014 spike is retired. Record: `docs/history/architecture-decisions.md`, "Registration on generic-arity slots in production (M3-015)".

## Easy to get wrong now

The current contract is `docs/ARCHITECTURE.md`, "Current architecture". Points a new session tends to miss:

- Typed handlers read headers only on `post`, through a `WithHeaders[B]` body. `WithHeaders` is a body-slot type but not a `FromBody` (the accepted cost): generic code bounded by `B: FromBody` does not take it. Header access on typed `get` handlers stays a target; on the arity overloads it is a `Headers` slot kind or the carrier, with no overload up to slot arity 2 (M3-014). The JSON `Content-Type` check is a separate verdict for `Json[T]` bodies only, not header extraction.
- `TestClient` sends header fields only through `headers=`: `client.post(target, body)` to a JSON body route is still 415, and `tests/test_json.mojo` pins that on purpose. The client never adds a field (no automatic `Content-Type`, no per-client defaults); a test that needs the field sends it.
- `get` and `post` have six overloads each (slot arities 0 to 2). A new shape is a slot kind or a rule in `_get_rule`/`_post_rule` plus its message in `_check`, not an overload; keep the rule order that preserves existing messages. Slot arity 3 makes eight overloads per method, 4 makes ten (Mojo 1.1.0's note cap, counted per method name; a rejected result then loses a candidate note), 5 is past it.
- `rebind_var` accepts a different struct with the same layout (`tests/registration_known_gaps`): every production use of `rebind_var` goes through `_as` after its type-equality assert (the import-free `rebind` is not checked; a follow-up) (exact for origin-free types; for `StaticString` results the `where` clause gives exactness), and `check_unsafe.sh` fails on any other `rebind_var[`, comments included. Write "the rebind" in prose; the existing unsafe pattern also matches the word `check_unsafe` inside `src/muntin`.
- Typed function values and helper parameters spell each request parameter `var` (`def(var Int) thin raises Never -> String`); a borrowed one is the `TODO: function type conversions` error. Plain `def` handlers are unaffected.
- M2 is closed again after M3-015's recorded reopen: a new item adds to the M2 contract; changing an M2 signature or the 400/404/500 boundary reopens M2 (`docs/ARCHITECTURE.md`, "When M2 reopens").
- `App.handle` is never called concurrently today; a concurrent backend or a `Copyable` `App` reopens the JSON cap and interior mutability in `State` values.
- `main` needs a pull request, up to date, with `ci-ok`; a change touching only `docs/` or `*.md` skips `verify` and `flare`.
Blockers: none.

## Temporary watch

Time-bound operational notes. Each says when to delete it.

- `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19. If the `flare` job breaks after that date, compare `ImageOS`/`ImageVersion` in the `runner image` step before blaming Muntin or Flare. Delete this once a `flare` job has passed on Ubuntu 26.

## Latest verification evidence

M3-015: `check.sh`, `test.sh` (30 files, 305 tests), `check_flare.sh`, `check_unsafe.sh` and `git diff --check` pass on the branch. All 278 must-fail fixtures of `main` were built against both `src` trees and compared in full; 44 production mutations were red. The PR review's blocking findings (generic forwarding outside M3-014's edges; the local-origin result error) are answered by the amendment record and a pinned fixture. Details: the M3-015 record.

## Next step

After PR #44 passes review and CI and merges, pick the next item from `docs/SPEC.md`, "Remaining candidates" (each is decision-first; typed `get` headers, `String` route values, more methods and `POST` without a body are now slot kinds or rules on the arity overloads).

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
