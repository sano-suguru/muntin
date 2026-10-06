# Muntin development loop

## 1. Orient

Read `AGENT_PROGRESS.md`, check `git status` and recent commits, and run the cheapest relevant check. Read the document that owns what the next change touches (section 7). Do not re-plan the project when the repository state is coherent.

## 2. Pick one increment

Take the next item that advances the active milestone and can be verified on its own: one observable outcome, a bounded file set, a real executable check, and no unrelated future work.

Uncertain areas are cut decision-first: a decision item compares candidates with pinned-compiler evidence (spikes and fixtures under `tests/`, `src/muntin` unchanged), records the choice and names one exact production slice, which becomes the next item; that slice is the production item's acceptance. A decision item states its question and what would settle it at the top of its record before measuring. For an uncertain Mojo feature, make a small compilation experiment before designing around it.

## 3. Verify with the strongest available oracle

A change is not complete because the code looks plausible. Use, as applicable: a focused executable test for the changed behavior, the broader suites, build/type/static checks, end-to-end execution, architecture/dependency checks, and `git diff --check`. A syntax-only check, a command that failed to start, or a skipped test is not passing evidence.

- `./scripts/check.sh`: toolchain version, formatting, architecture boundary, unsafe confinement, package and example builds, the library-only spike drivers, and every must-not-build and must-build fixture under `tests/` (in parallel; reports in file order). It does not build `tests/test_*.mojo`.
- `./scripts/test.sh [FILE...]`: builds each `tests/test_*.mojo` (or the named files) with `--Werror` in parallel, then runs them one at a time.
- `./scripts/check_flare.sh`: the Flare adapter and its localhost round trips, in the `flare` environment.

A must-not-build fixture states its expected diagnostic on a line starting `# Expected diagnostic (checked by scripts/check.sh): `; `scripts/build_one.sh` reads it.

## 4. CI and merging

CI runs on pull requests only. `verify` (`check.sh` with `git diff --check`, and `test.sh`, as separate jobs) and `flare` run on ubuntu-latest and macos-latest, except when every changed file is under `docs/` or ends in `.md`; then both are skipped. `ci-ok` passes only when both ran and passed, or both were skipped for a docs-only change; it is the one required status check for `main`, where a ruleset also requires a pull request that is up to date with `main`. A new push cancels the running checks; nothing reruns after a merge.

## 5. Review important boundaries skeptically

For public API, architecture, ownership/lifetime, backend seam, unsafe code or dependency changes, use a fresh-context review when practical. It should look for backend details leaking into Muntin APIs, inverted dependencies, acceptance weakened by tests, tests that bypass real dispatch, lifetime assumptions that hold for one backend only, speculative abstractions, and application verbosity added for internal convenience. Review counts as evidence only when the reviewer inspected the diff and the verification results.

## 6. Record the result

After verification, and after CI passes on the pull request, set the item's `passes` to `true` in `feature_list.json`. Then update only the owners the change affected (section 7), rewrite `AGENT_PROGRESS.md` for the next session, and commit. Test counts, mutation lists, review findings and CI runs go in the pull request description, not in the repository.

## 7. Where information lives

Each fact has one owner. Other documents link to it instead of restating it.

| Information | Owner |
|---|---|
| how to use Muntin: API, examples, user-visible semantics and diagnostics | `docs/DX.md` |
| how Muntin works now: invariants, registration, request handling, storage, backend seam, current limits, revisit index | `docs/ARCHITECTURE.md` |
| why: the decision, candidates, costs, measured premises, revisit conditions, the next production slice | `docs/history/architecture-decisions.md`, one record per decision or production slice |
| product scope: milestones, shipped and remaining capabilities, product boundaries, the M2 contract | `docs/SPEC.md` |
| item completion state | `feature_list.json` (`id`, `passes`) |
| what to do next | `AGENT_PROGRESS.md` |
| behavior and invariants | tests, fixtures, `scripts/` and CI |
| upstream sources and the Flare pin | `docs/REFERENCES.md`, `pixi.lock` |

A new decision adds its record and, when it pins fixtures, a revisit index row. A production slice updates the affected subsection of "Current architecture" to state the new result, without history.

## 8. Stop at the requested boundary

When the active goal is satisfied, stop. Mention attractive follow-ups instead of implementing them.
