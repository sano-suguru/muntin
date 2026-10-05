# Agent progress

The current handoff between coding sessions: state, what is easy to get wrong now, the latest evidence and the next step. Detail belongs in the documents it points to; when a new slice lands, the previous slice's description goes. Earlier per-item results, mutation lists and command logs are in [`docs/history/progress-log.md`](docs/history/progress-log.md), which is also what `feature_list.json` means when an earlier item says `AGENT_PROGRESS.md` records or lists something (results, merged PRs, mutation lists, command logs).

## Active milestone

M3 (composition and production ergonomics) is active. M0, M0.5, M1 and M2 are complete (M2 closed by M2-016, PR #24; contract in `docs/SPEC.md`, "M2 completion contract"). Every feature in `feature_list.json` up to M3-014 has `passes: true` (M3-014: PR #43). M3-015 (PR #44) is `passes: false` until CI passes on the PR's latest HEAD; its reviews have converged. M3-016 (PR #45, a decision) is stacked on PR #44; M3-017 is its production slice.

M3 so far:

| Area | Decision | Production |
|---|---|---|
| application state | M3-001 (`State[S]` bound at registration, PR #25); M3-004 (sealed `_Shared` storage, PR #27) | M3-003 stateful `get` (PR #26), M3-006 stateful `post` (PR #30), M3-007 stateful raw (PR #31) |
| headers | M3-002 (`muntin.Headers`, PR #28) | M3-005 (PR #29) |
| JSON | M3-008 (`Json[T]` over `FromJson`/`ToJson`, PR #32) | M3-009 (PR #36) |
| `TestClient` request headers | M3-010 (PR #39) | M3-011 (PR #40) |
| typed header access | M3-012 (`WithHeaders[B]` body carrier on `post`, PR #41) | M3-013 (PR #42) |
| registration structure | M3-014 (generic-arity slots on `get`/`post`, PR #43) | M3-015 (PR #44, in review; reopens M2) |
| typed header access on `get` | M3-016 (`Headers` slot, last, PR #45) | M3-017 (next) |

## Current increment

M3-016 (decision; `src/muntin` and `adapters/` unchanged): typed header access on `get` is a `Headers` request slot, the handler's last request parameter after at most one `Int` route value (`def(Headers)`, `def(Int, Headers)`, the same after `State[S]`), through the existing six overloads. The handler gets a fresh `Headers` rebuilt from the transported fields (M3-002's semantics; no Muntin status for a field; the only added pre-handler failure is the rebuild's fixed 500); the existing `_Route.headers` transport carries it, with `App.handle` unchanged. `post` keeps `WithHeaders[B]` and every `Headers` message it has. The `get` no-kind message is reworded to name `Headers` (its fixtures are re-pinned in M3-017). Rejected: other positions (the rule alone crashes on the first request), a wrapper type, `FromHeaders`, deferral. Evidence: `tests/get_headers_spike.mojo`, `tests/test_spike_get_headers.mojo`, `tests/get_headers_fail`; a scratch copy measured against M3-015 in full. Record and the exact M3-017 slice: `docs/history/architecture-decisions.md`, "Typed get header access decision (M3-016)".

## Easy to get wrong now

The current contract is `docs/ARCHITECTURE.md`, "Current architecture". Points a new session tends to miss:

- Typed handlers read headers only on `post` today, through a `WithHeaders[B]` body. `WithHeaders` is a body-slot type but not a `FromBody` (the accepted cost): generic code bounded by `B: FromBody` does not take it. Typed `get` header access is decided (M3-016: a `Headers` slot, last, by exact type equality) and not yet production (M3-017). `post` takes no `Headers` slot, and M3-017 must keep every `post` message for a `Headers` shape (`tests/get_headers_fail/post_*`). The JSON `Content-Type` check is a separate verdict for `Json[T]` bodies only, not header extraction.
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

- This branch (M3-016, PR #45) is stacked on PR #44 (M3-015), which is frozen at its HEAD: add no commit to #44, keep M3-015 `passes: false` until #44's CI passes there, and do not merge #45 before #44. After #44 merges, rebase this branch onto `main`, rerun `check.sh`, `test.sh`, `check_flare.sh` and `git diff --check`, check `git diff main -- src/muntin adapters` is empty, and let #45's own CI run before considering a merge. Delete this note once the branch is rebased onto a `main` that contains M3-015.
- `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19. If the `flare` job breaks after that date, compare `ImageOS`/`ImageVersion` in the `runner image` step before blaming Muntin or Flare. Delete this once a `flare` job has passed on Ubuntu 26.

## Latest verification evidence

M3-016: `check.sh` (with `tests/get_headers_fail`), `test.sh` (the spike test included), `check_flare.sh` and `git diff --check` pass on the branch, and `git diff 37a1c7a -- src/muntin adapters` is empty. The selected design was measured on a scratch copy of M3-015 (its `check.sh`, `test.sh` and `check_flare.sh` pass; every fixture's diagnostic compared in full); spike and scratch mutations are red. Full evidence: the M3-016 record. M3-015's evidence: its record; CI on PR #44's latest HEAD is still required.

## Next step

After CI passes on PR #44's latest HEAD, set M3-015 `passes: true`; after PR #44 merges, rebase this branch onto `main` (Temporary watch), rerun the checks and #45's CI, then set M3-016 `passes: true` once CI and a fresh-context review of the final HEAD pass. Then M3-017, exactly the record's "Next production slice (M3-017)".

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
