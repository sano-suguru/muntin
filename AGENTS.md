# Muntin project instructions

## Mission
Build Muntin: a small, Mojo-native, typed web application framework whose public API is owned by this repository and whose networking backends are replaceable.

## Constitutional documents
Before substantial work, read the documents relevant to the change:
- `docs/DX.md` defines the intended user-facing API and ergonomics.
- `docs/ARCHITECTURE.md` defines dependency boundaries and invariants.
- `docs/SPEC.md` defines milestone scope and acceptance criteria.
- `docs/DEVELOPMENT.md` defines the engineering/verification loop.
- `feature_list.json` is the machine-readable completion state.
- `AGENT_PROGRESS.md` is the previous-session handoff.

If these disagree, do not silently pick one. Preserve established architecture/safety invariants, identify the inconsistency, and update the documents deliberately as part of the same verified change.

## Session start
Before changing code:
- inspect `pwd`, `git status --short`, and recent local commits when git exists;
- read `AGENT_PROGRESS.md` and `feature_list.json`;
- run the cheapest existing smoke/check command;
- choose the smallest failing feature that advances the active milestone.

## Working rules
- Work on one coherent feature or defect at a time.
- Keep Muntin's public API free of Flare-specific types, imports, routers, middleware contracts, lifecycle types, and reactor/runtime concepts.
- Treat Flare as an optional transport/backend implementation, not as Muntin's constitution.
- Do not build a custom socket, TLS, HTTP/2, HTTP/3, QUIC, reactor, executor, or async runtime unless an accepted milestone explicitly requires it.
- Prefer a vertical slice with an executable oracle over broad scaffolding.
- Do not implement speculative M1+ features while M0 acceptance remains unmet.
- Do not weaken, delete, or rewrite acceptance criteria or tests merely to make them pass.
- Never mark a feature passing until a real executable check exercises the requirement successfully. Syntax-only checks, commands that failed to start, and inspection alone are not passing evidence.
- When CI fails, first classify the cause (Muntin bug, toolchain bug, packaging, runner/image). Do not change Muntin core to work around a non-Muntin cause.
- When current Mojo or dependency behavior matters, verify it from the installed toolchain and/or authoritative upstream documentation instead of guessing.
- Treat `docs/DX.md` examples as design constraints. If current Mojo cannot express one exactly, prove the limitation with a minimal reproduction and implement the closest type-safe alternative.
- For architecture, ownership/lifetime, backend-seam, or public-API changes, use a fresh-context skeptical review when practical.
- Update `AGENT_PROGRESS.md` after each verified increment and add concrete command evidence to `feature_list.json`.
- Commit coherent verified increments locally when git is initialized. Never push, publish, release, or change remote infrastructure without explicit user instruction.

## Completion behavior
Keep working while the active goal has unmet, unblocked criteria. A progress summary is not proof of completion.
Stop to ask only when user input is genuinely required or before a risky/irreversible external action.
When the requested work is complete and verified, stop. Do not add unrelated features, docs, refactors, or tests; mention useful follow-ups instead.

## Which document to update
Update a document only when its subject changed:
- public API changed → `docs/DX.md`
- dependency boundary or seam changed → `docs/ARCHITECTURE.md`
- milestone scope or acceptance changed → `docs/SPEC.md` and `feature_list.json`
- end of a verified increment → `AGENT_PROGRESS.md`
- ordinary implementation → code and tests only

## Canonical verification
Once bootstrap creates them, prefer:
- `./scripts/check.sh` for formatting/static/build checks;
- `./scripts/test.sh` for executable tests and contract tests;
- `git diff --check` for patch/whitespace sanity.

If these scripts do not exist yet, creating minimal reliable versions is part of M0.

## Pull requests
PR descriptions minimize the reviewer's decision cost and follow `.github/pull_request_template.md`. Unless it materially affects the review, do not include:
- commit-by-commit summaries;
- tool or model provenance (such as "Generated with Claude Code" or "Generated with Codex"); attribution belongs in commit trailers;
- compiler output already recorded in the docs;
- narration of effort or process.

Do not fill template sections mechanically: Decision, Changes and Verification are required; delete optional sections that add no review-relevant information.
