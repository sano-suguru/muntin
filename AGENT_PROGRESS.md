# Agent progress

Current handoff only. Rewrite it when the work changes; history is git and the pull requests.

## Now

Next item: M3-019, `String` route values, exactly as the "Next production slice" of [String route value decision (M3-018)](docs/history/architecture-decisions.md#string-route-value-decision-m3-018) states it. Blockers: none.

## Easy to miss

- `get` and `post` have six overloads each (slot arities 0 to 2). A new shape is a slot kind or a rule in `_get_rule`/`_post_rule` plus its message in `_check`, not an overload; keep the rule order that preserves existing messages. Slot arity 4 is ten overloads per method, Mojo 1.1.0's note cap.
- `check_unsafe.sh` requires exactly one `rebind_var[` in `src/muntin`, comments included: write "the rebind" in prose.
- `TestClient` adds no header field: a JSON body route answers `client.post(target, body)` with 415 unless the test passes `headers=`.

## Temporary watch

- `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19. If the `flare` job breaks after that, compare `ImageOS`/`ImageVersion` in the `runner image` step before blaming Muntin or Flare. Delete this once a `flare` job has passed on Ubuntu 26.
