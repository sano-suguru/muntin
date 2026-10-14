# Agent progress

Current handoff only: the next action, its blockers and temporary watches. Rewrite it when the work changes; history is git and the pull requests. A fact about how Muntin works belongs in `docs/ARCHITECTURE.md`, not here (`docs/DEVELOPMENT.md` section 7).

## Now

M3-048 (bodyless typed `post`, `put` and `patch` handlers: [Bodyless typed post, put and patch handlers decision (M3-048)](docs/history/architecture-decisions.md#bodyless-typed-post-put-and-patch-handlers-decision-m3-048), decision and production) has merged. Next: no item is named next. Choose one coherent item from `docs/SPEC.md`, "Remaining candidates"; make it a decision item only if it opens a new design question (`docs/DEVELOPMENT.md` section 2). Blockers: none.

## Temporary watch

- `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19. If the `flare` job breaks after that, compare `ImageOS`/`ImageVersion` in the `runner image` step before blaming Muntin or Flare. Delete this once a `flare` job has passed on Ubuntu 26.
