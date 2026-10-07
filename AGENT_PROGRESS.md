# Agent progress

Current handoff only. Rewrite it when the work changes; history is git and the pull requests.

## Now

No item is named next. Choose one coherent item from `docs/SPEC.md`, "Remaining candidates"; make it a decision item only if it opens a new design question (`docs/DEVELOPMENT.md` section 2). Blockers: none.

## Easy to miss

- Each registration method (`get`, `post`, `put`, `patch`, `delete`) has eight overloads (slot arities 0 to 3). `put` and `patch` are copies of `post` and use `_post_rule`; `delete` is a copy of `get` and uses `_get_rule`. A rule or message change to a shape family therefore applies to every method in it, and `_check` builds each method-naming message from the method's lowercase name. A new shape is a slot kind or a rule in `_get_rule`/`_post_rule` plus its message in `_check` (where they live: `docs/ARCHITECTURE.md`, "Modules and public surface"), not an overload; keep the rule order that preserves existing messages. Route values are decoded once in `App.handle`, at capture (path captures, then `_Route.query_keys` in the literal's order); a slot converts decoded text and never decodes. For a key whose value binds an `Optional` slot (`_Route.query_optional`), an absent key or an empty value is passed on as `""`, which no decoded value is, and the slot reads it as `None`. The distinct-query-keys rule runs in `_rule` after the family rule accepts. Slot arity 4 would add two overloads to every method name and reach ten per method, Mojo 1.1.0's note cap.
- `HEAD` is answered by `GET` routes in `App.handle`, body included; the content is dropped and the length declared by the network backend (`MuntinHandler.serve`, at every exit, not `to_flare_response`, which takes no method). A change to what a `get` route answers changes its `HEAD` answer too, and a new backend inherits the framing duty (`docs/ARCHITECTURE.md`, "Backend seam").
- `check_unsafe.sh` requires exactly one `rebind_var[` in `src/muntin`, comments included: write "the rebind" in prose.
- `check_flare.sh` builds the two binaries that reach Flare's `HttpClient` (the round trip and the JSON probe) without `--Werror`, because Flare v0.12.0 warns on one line of its own source (`KNOWN_WARNING`). Any other warning fails them, and so does that warning disappearing: then build them with `--Werror` again. Every other build in that parallel step is `--Werror`.
- `TestClient` adds no header field: a JSON body route answers `client.post(target, body)` (or `put`, `patch`) with 415 unless the test passes `headers=`. `TestClient.delete` sends an empty body; a test that needs a `DELETE` body builds the `Request` and calls `App.handle`.

## Temporary watch

- `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19. If the `flare` job breaks after that, compare `ImageOS`/`ImageVersion` in the `runner image` step before blaming Muntin or Flare. Delete this once a `flare` job has passed on Ubuntu 26.
