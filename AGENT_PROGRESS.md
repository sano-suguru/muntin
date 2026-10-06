# Agent progress

Current handoff only. Rewrite it when the work changes; history is git and the pull requests.

## Now

Next item: M3-023, two route values, exactly as the "Next production slice" of [Several route values decision (M3-022)](docs/history/architecture-decisions.md#several-route-values-decision-m3-022) specifies. Blockers: none.

## Easy to miss

- Each registration method (`get`, `post`, `put`, `patch`, `delete`) has six overloads (slot arities 0 to 2). `put` and `patch` are copies of `post` and use `_post_rule`; `delete` is a copy of `get` and uses `_get_rule`. A rule or message change to a shape family therefore applies to every method in it, and `_check` builds each method-naming message from the method's lowercase name. A new shape is a slot kind or a rule in `_get_rule`/`_post_rule` plus its message in `_check`, not an overload; keep the rule order that preserves existing messages. Route values are decoded once in `App.handle`, at capture; a slot converts decoded text and never decodes. Slot arity 3 adds two overloads to every method name, and slot arity 4 reaches ten per method, Mojo 1.1.0's note cap.
- `check_unsafe.sh` requires exactly one `rebind_var[` in `src/muntin`, comments included: write "the rebind" in prose.
- `TestClient` adds no header field: a JSON body route answers `client.post(target, body)` (or `put`, `patch`) with 415 unless the test passes `headers=`. `TestClient.delete` sends an empty body; a test that needs a `DELETE` body builds the `Request` and calls `App.handle`.

## Temporary watch

- `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19. If the `flare` job breaks after that, compare `ImageOS`/`ImageVersion` in the `runner image` step before blaming Muntin or Flare. Delete this once a `flare` job has passed on Ubuntu 26.
