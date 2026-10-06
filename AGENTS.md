# Muntin project instructions

## Mission
Build Muntin: a small, Mojo-native, typed web application framework whose public API is owned by this repository and whose networking backends are replaceable.

## Where to look
- `AGENT_PROGRESS.md`: what to do next. Read it first.
- `docs/DX.md`: the user-facing API and its semantics; its examples are design constraints.
- `docs/ARCHITECTURE.md`: how Muntin works now, its invariants and the revisit index.
- `docs/history/architecture-decisions.md`: why, per decision; the contract of the next production item (its "Next production slice").
- `docs/SPEC.md`: product scope and remaining capabilities.
- `docs/DEVELOPMENT.md`: verification commands, CI, and which document owns which fact.

If these disagree, do not silently pick one. Preserve established architecture and safety invariants, identify the inconsistency, and fix the owning document in the same verified change.

## Working rules
- Start each session by checking `git status`, recent commits and the cheapest relevant check.
- Work on one coherent item or defect at a time; prefer a vertical slice with an executable oracle over broad scaffolding.
- Keep Muntin's public API free of Flare-specific types, imports, routers, middleware contracts, lifecycle types, and reactor/runtime concepts. Flare is an optional backend, not Muntin's constitution.
- Do not build a custom socket, TLS, HTTP/2, HTTP/3, QUIC, reactor, executor, or async runtime unless an accepted milestone explicitly requires it.
- Do not weaken, delete, or rewrite acceptance criteria or tests merely to make them pass.
- Never report an item done until a real executable check exercises it successfully. Syntax-only checks, commands that failed to start, and inspection alone are not passing evidence. An item is complete when its pull request merges; `main` requires CI to pass first.
- When CI fails, first classify the cause (Muntin bug, toolchain bug, packaging, runner/image). Do not change Muntin core to work around a non-Muntin cause.
- When current Mojo or dependency behavior matters, verify it with the installed toolchain or authoritative upstream documentation instead of guessing. If a `docs/DX.md` example cannot be expressed, prove the limitation with a minimal reproduction and implement the closest type-safe alternative.
- For architecture, ownership/lifetime, backend-seam, or public-API changes, use a fresh-context skeptical review when practical.
- Each fact has one owner (`docs/DEVELOPMENT.md`, "Where information lives"). Update the owner; elsewhere link to it rather than copying it.
- Commit coherent verified increments locally. Never push, publish, release, or change remote infrastructure without explicit user instruction.

## Completion behavior
Keep working while the active goal has unmet, unblocked criteria. A progress summary is not proof of completion.
Stop to ask only when user input is genuinely required or before a risky/irreversible external action.
When the requested work is complete and verified, stop. Do not add unrelated features, docs, refactors, or tests; mention useful follow-ups instead.

## Pull requests
PR descriptions minimize the reviewer's decision cost and follow `.github/pull_request_template.md`. Unless it materially affects the review, do not include:
- commit-by-commit summaries;
- tool or model provenance (such as "Generated with Claude Code" or "Generated with Codex"); attribution belongs in commit trailers;
- compiler output already recorded in the docs;
- narration of effort or process.

Do not fill template sections mechanically: Decision, Changes and Verification are required; delete optional sections that add no review-relevant information.
