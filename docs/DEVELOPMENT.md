# Muntin development loop

This repository is structured for long-running agentic development while keeping progress auditable, test-driven, and recoverable.

## 1. Orient before editing

At the start of a session:

1. inspect the working directory and repository status;
2. read `AGENT_PROGRESS.md`;
3. read `feature_list.json`;
4. inspect recent local commits;
5. run the cheapest existing smoke/check command;
6. read the constitutional document relevant to the next change (`DX`, `ARCHITECTURE`, or `SPEC`).

Do not re-plan the whole project from scratch when repository evidence is already coherent.

## 2. Select the smallest useful increment

Choose the highest-priority failing feature that advances the active milestone and can be verified independently.

A good increment has one observable outcome, a bounded file set, a real executable acceptance check, and no unrelated future-milestone work.

Do not mark several features passing because one command happened to succeed unless that command truly exercises every criterion.

## 3. Establish the contract before implementation

For a public-API or architecture change, write down what success means before coding. Use the existing feature acceptance criteria; if they are genuinely incomplete, update them deliberately before implementation and explain why.

Never weaken acceptance because the implementation is inconvenient.

For an uncertain Mojo feature, make a small compilation experiment first. This is especially important for compile-time string parameters, callable introspection, reflection, ownership/lifetimes, and error semantics.

## 4. Investigate only what is needed

For changing external APIs, prefer authoritative upstream documentation and the installed toolchain.

Keep broad research from dominating the implementation context. A fresh context/subagent may investigate a narrow question and return only conclusions, constraints, minimal reproductions, and source links.

## 5. Implement a vertical slice

Prefer one path that works end to end over many unfinished abstractions.

For M0, a real `GET /hello` application dispatch is more valuable than elaborate generic router types that have never handled a request.

For M1, one real localhost request through the Flare adapter is more valuable than wrapping every Flare feature.

## 6. Verify with the strongest available oracle

A change is not complete because the code looks plausible.

Use, in order as applicable:

1. a focused executable test for the changed behavior;
2. broader project tests;
3. build/type/static checks;
4. end-to-end/example execution;
5. architecture/dependency checks;
6. `git diff --check`.

A syntax-only check, a test command that failed to start, or a skipped test due to missing declared dependencies is not passing evidence.

Record the exact successful commands in the feature's `evidence` array.

The canonical commands:

- `./scripts/check.sh`: toolchain, formatting, architecture boundary, unsafe confinement, package and example builds, the library-only spike drivers (built in parallel), and every must-not-build and must-build fixture under `tests/` (built in parallel, one job per CPU, reports printed in file order). It does not build `tests/test_*.mojo`.
- `./scripts/test.sh [FILE...]`: builds each `tests/test_*.mojo` (or only the named files) with `--Werror` in parallel, then runs the binaries one at a time. With no arguments it runs every test file; CI always runs it without arguments.
- `./scripts/check_flare.sh`: the Flare adapter and its localhost round trips, in the `flare` environment (binaries built in parallel, then run in order).

CI runs on pull requests only. `verify` (`check.sh` with `git diff --check`, and `test.sh`, as separate jobs) and `flare` run on ubuntu-latest and macos-latest, except when every changed file is under `docs/` or ends in `.md`; then both are skipped. `ci-ok` always runs and passes only when both ran and passed, or both were skipped for a docs-only change; it is the one required status check for `main`, where a repository ruleset also requires a pull request that is up to date with `main`. A new push to a pull request cancels its running checks. Nothing reruns after a merge.

## 7. Review important boundaries skeptically

For public API, architecture, ownership/lifetime, backend seam, unsafe code, or dependency changes, use an independent/fresh-context review when practical.

The reviewer should actively try to find:

- Flare or backend details leaking into Muntin APIs;
- accidental coupling in imports/dependencies;
- acceptance criteria silently weakened by tests;
- bypass paths where tests do not exercise real routing/dispatch;
- lifetime or ownership assumptions that only work for one backend;
- speculative abstractions without a current consumer;
- application API verbosity introduced only for internal convenience.

Treat review approval as evidence only when the reviewer has inspected the relevant diff and verification results.

## 8. Update state after proof

Only after successful verification:

- change `passes` from `false` to `true` for the satisfied feature;
- append concrete evidence rather than prose like "works now";
- update `AGENT_PROGRESS.md` with the new verified state and next smallest step, replacing the previous slice's summary (append that summary to `docs/history/progress-log.md` if it records something not kept elsewhere);
- update the documents section 9 assigns to the change, each once;
- make a local coherent commit when git is initialized.

Do not rewrite feature descriptions or acceptance criteria as a routine way to achieve passing state.

## 9. Keep handoffs small

`AGENT_PROGRESS.md` is not a diary. It should tell the next session:

- what is verified;
- what is broken or blocked;
- what decision is currently in force;
- what exact command last passed/failed;
- what to do next.

Large design explanations belong in `docs/`, not the handoff. Keep it near 1,000 words; if it grows past that, move what is no longer current to `docs/history/progress-log.md`.

Each kind of detail has one canonical place. Write it there once and link to it from the other documents instead of restating it:

| Detail | Canonical place |
|---|---|
| decision record: the contract as decided, reasons, compiler evidence, rejected candidates, mutations, review findings, "Revisit when", the next production slice; and the production record of each slice (what changed, diagnostics, test counts) | `docs/history/architecture-decisions.md`, one `###` record per item, with a row in `docs/ARCHITECTURE.md`'s decision index (and its revisit index when it pins a fixture) |
| current architecture contract | `docs/ARCHITECTURE.md`, "Current architecture": edit the affected subsection to state the new result; do not append history there |
| current public API, runnable examples, current limits, targets | `docs/DX.md` (the status table and the section's status) |
| milestone scope, open item scope, remaining candidates | `docs/SPEC.md`; when an item merges, move its scope and result paragraphs to `docs/history/spec-items.md` and keep one row in the item table |
| acceptance, `passes`, executable evidence | `feature_list.json`; evidence states the commands, counts and CI result briefly and points to the record for narrative |
| current handoff | `AGENT_PROGRESS.md` |

Test counts, mutation lists and review narratives go in the record only. A long paragraph in a record keeps contract, reasons, evidence, limits and revisit conditions in separate labeled parts.

## 10. Stop at the requested boundary

When the active goal and milestone criteria are satisfied, stop. Do not use leftover context to add unrelated framework features.

If an attractive follow-up exists, record it as a future feature or mention it in the completion report rather than implementing it opportunistically.

## Why this loop exists

Long-running coding agents can prematurely declare victory, lose context across sessions, and over-trust their own evaluation. Muntin therefore keeps durable state in structured repository artifacts and uses executable verification as the completion oracle.

See `docs/CLAUDE_CODE.md` and `docs/REFERENCES.md` for the Anthropic guidance that motivated this structure.
