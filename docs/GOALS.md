# Claude Code `/goal` conditions for Muntin

Use these as completion conditions after the repository files are present. The detailed specification stays in the repository; `/goal` states what must be demonstrably true before the run is allowed to finish.

## M0 — architecture bootstrap

Paste at the beginning of the M0 run:

```text
/goal Complete Muntin milestone M0 in docs/SPEC.md while preserving docs/DX.md and docs/ARCHITECTURE.md. The goal is met only when: (1) the repository is a valid project for the verified stable Mojo toolchain and records that exact version; (2) ./scripts/check.sh exits 0 and performs real project checks; (3) ./scripts/test.sh exits 0 and includes an executable application-dispatch test proving GET /hello returns status 200 with body hello through Muntin-owned App/Request/Response or their proven equivalents; (4) an in-memory/reference backend or TestClient drives that same application seam without opening a socket and without Flare; (5) Muntin core/public modules do not import or expose Flare types; (6) every M0 feature in feature_list.json is marked passing only after concrete successful command evidence exists; (7) AGENT_PROGRESS.md and architecture/DX docs match the verified implementation; (8) git diff --check exits 0; and (9) the final turn reports the exact verification commands and successful results. Do not weaken tests or acceptance criteria to make them pass. Do not implement unrelated M1+ features. Do not build a custom socket/TLS/HTTP2/HTTP3/QUIC/reactor/executor/async runtime. If a desired DX syntax is unsupported by current Mojo, prove the limitation with a minimal executable/compiler reproduction and use the closest type-safe design without leaking backend details. If one external issue is blocked, record the exact evidence and continue all independent M0 work; stop as impossible only when an M0 requirement truly cannot be satisfied in this environment.
```

## M1 — Flare adapter

Use only after all M0 and M0.5 features have executable passing evidence and the M0.5 feasibility result is accepted. M1 must not expose or depend on the provisional M0.5 handler storage:

```text
/goal Complete Muntin milestone M1 in docs/SPEC.md by adding a pinned released Flare backend behind the existing Muntin backend seam. The goal is met only when: (1) compatible Mojo and Flare versions are recorded reproducibly; (2) application handlers and public Muntin Request/Response/App contracts remain free of Flare types; (3) Muntin core does not import Flare and the adapter depends inward on Muntin contracts; (4) adapter contract tests pass; (5) a real localhost HTTP request travels through Flare -> Muntin adapter -> Muntin application dispatch -> response and returns the expected status/body; (6) the same application behavior is still exercised successfully by the in-memory backend; (7) all M0 checks remain passing without weakening their intent; (8) ./scripts/check.sh, ./scripts/test.sh, and git diff --check exit 0; (9) feature_list.json and AGENT_PROGRESS.md contain concrete evidence; and (10) the final turn shows the exact successful verification commands. Do not replace Muntin's application/router model with Flare's APIs, do not expose Flare publicly, and do not expand into unrelated M2 features. If Flare and the current Mojo toolchain are incompatible, preserve M0 architecture and document the smallest reproducible incompatibility before declaring the goal blocked.
```

## M2 — first typed-route vertical slice

Do not attempt all M2 ergonomics at once. Start with one typed path parameter:

```text
/goal Implement the first Muntin M2 typed-route vertical slice: a canonical route equivalent to GET /users/{id} must deliver id to an application handler as Int without application code manually parsing a string, while preserving transport independence. Before choosing syntax, verify current stable Mojo support for the desired compile-time route form in docs/DX.md with a minimal compilation experiment. The goal is met only when: (1) the chosen public API is documented in docs/DX.md as proven, including any Mojo limitation that forced a syntax change; (2) valid /users/42 dispatch produces handler input Int(42); (3) invalid integer input produces the documented client error behavior; (4) the behavior passes through the in-memory Muntin path and, if M1 exists, the Flare path without different application handler signatures; (5) no Flare type leaks into the public API; (6) focused tests plus ./scripts/check.sh, ./scripts/test.sh, and git diff --check pass; (7) feature_list.json and AGENT_PROGRESS.md record exact evidence. Do not add query extraction, JSON bodies, OpenAPI, middleware, DI, or unrelated M2 features in this run.
```

## Review goal — architecture/public API

Run in a fresh context after a substantial seam or public-API change:

```text
/goal Review the current Muntin diff skeptically against docs/DX.md, docs/ARCHITECTURE.md, docs/SPEC.md, and the active feature acceptance criteria. The review is complete only when you have inspected the actual changed code and relevant tests, run or independently verify the applicable canonical checks, and either (a) report no material correctness/architecture/API issues with supporting evidence or (b) identify concrete issues with file/behavior-level evidence. Specifically look for Flare/backend leakage, reversed dependency direction, tests that bypass real Muntin dispatch, acceptance criteria weakened to fit implementation, speculative abstractions, lifetime/ownership assumptions tied to one backend, and public API boilerplate introduced only for internal convenience. Do not modify code unless explicitly asked; this goal is independent evaluation.
```
