# Muntin development loop

## 1. Orient

Read `AGENT_PROGRESS.md`, check `git status` and recent commits, and run the cheapest relevant check. Read the document that owns what the next change touches (section 7). Do not re-plan the project when the repository state is coherent.

## 2. Pick one increment

Take one coherent item that can be verified on its own: one observable outcome, a bounded file set, a real executable check, and no unrelated future work. For an uncertain Mojo feature, make a small compilation experiment before designing around it.

Where an item's contract is written depends on its kind, and nowhere else:

| Item | Its contract | Written when |
|---|---|---|
| decision (a design question, settled with evidence suited to it: existing records and pull requests where they suffice, spikes and fixtures under `tests/` where compiler or runtime behavior must be measured; `src/muntin` unchanged) | its new record in `docs/history/architecture-decisions.md`: the question and what would settle it, then the choice and exactly one next action: a "Next production slice", or an explicit deferral with a concrete revisit condition | the question and settling condition before any measurement; the choice and next action after the evidence |
| production (implements a decided slice) | the decision record's "Next production slice", as written | already, by the decision item |
| production that cannot follow its slice as written | an amendment record: the delta to the slice, why, and the invariant or compatibility boundary it affects | before the change merges; a new design question is a new decision item, not an amendment |
| fix, behavior-preserving refactor, tooling or docs with no design question | the pull request | with the pull request |

A product item, decision or production, gets a milestone ID (`M3-017`) where it is first named: a decision record's title or its "Next production slice". A process or tooling decision gets none unless `docs/SPEC.md` tracks it as milestone work. `docs/SPEC.md` and `AGENT_PROGRESS.md` refer to it; nothing else tracks it.

## 3. Verify with the strongest available oracle

A change is not complete because the code looks plausible. Use, as applicable: a focused executable test for the changed behavior, the broader suites, build/type/static checks, end-to-end execution, architecture/dependency checks, and `git diff --check`. A syntax-only check, a command that failed to start, or a skipped test is not passing evidence.

- `./scripts/check.sh`: toolchain version, formatting, architecture boundary, unsafe confinement, package and example builds, the library-only spike drivers, and every must-not-build and must-build fixture under `tests/` (in parallel; reports in file order). `CHECK_SHARD=I/N` builds only every N-th fixture, starting at the I-th, and still runs every other step; CI uses it. It does not build `tests/test_*.mojo`.
- `./scripts/test.sh [FILE...]`: builds each `tests/test_*.mojo` (or the named files) with `--Werror` in parallel, then runs them one at a time.
- `./scripts/check_flare.sh`: the Flare adapter and its localhost round trips, in the `flare` environment.

A must-not-build fixture states its expected diagnostic on a line starting `# Expected diagnostic (checked by scripts/check.sh): `; `scripts/build_one.sh` reads it.

CI runs all three scripts on every pull request that changes code (section 4); a passing `ci-ok` on the final HEAD is the evidence that they pass, and running them locally first is the author's choice. Beyond that, a production item adds the following ([why](history/architecture-decisions.md#production-verification-policy-decision)):

- Tests and fixtures for the new behavior. Each behavior, diagnostic or invariant that the item newly documents as guaranteed in `docs/DX.md` or `docs/ARCHITECTURE.md` needs executable evidence that fails if the claim stops being true. Rationale, costs and descriptions of the current implementation are not such claims. Where no test or fixture plainly targets a claim, a mutation planted in a scratch copy shows whether one does; nothing counts mutations.
- Each new must-not-build fixture that pins the change is also built against the base's `src`, and the pull request says whether it fails there with the same text. One that does is a regression pin, not evidence for the change.
- A comparison of every existing fixture's whole normalized compiler output against the base, when the change can alter compiler output outside the checked expected texts: overload resolution or the candidate set, the signatures candidate notes print, the instantiation or call-chain frames, or the compiler itself. Examples: a `get` or `post` overload added or removed, an overload's signature or `where` clause, `_check`'s parameters or the call chain to it, the Mojo version. A rule's branch or message (`_kind`, `_get_rule`, `_post_rule`, the text in `_check`) changes only the message line, which the expected texts check.
- When the change can reach the wire (`adapters/`, `compat/`, the `Request`, `Response` or `Headers` types or their conversion, how `App.handle` reads the request or builds the response, a limit or status that depends on the backend): a local `check_flare.sh` run before pushing, because a failure in the `flare` environment is slow to iterate on through CI, and loopback coverage of the changed wire behavior, preferably by extending an existing case in `adapters/flare/test_localhost_roundtrip.mojo`, and by a new case only where none can observe it. The adapter converts every request the same way whatever the route, so a new handler shape proven through `App.handle` needs no loopback case.

A "Next production slice" may require more only for a concrete risk this list does not cover, and names that risk. Such a check belongs to that item; it becomes a requirement for later items only if this section is changed to say so.

## 4. CI and merging

CI runs on pull requests only. `verify` (`check.sh` with `git diff --check` as two jobs that each build half of the fixtures, and `test.sh` as a third) and `flare` run on ubuntu-latest and macos-latest, except when every changed file is under `docs/` or ends in `.md`; then both are skipped. `ci-ok` passes only when both ran and passed, or both were skipped for a docs-only change; it is the one required status check for `main`, where a ruleset also requires a pull request that is up to date with `main`. A new push cancels the running checks; nothing reruns after a merge.

## 5. Review important boundaries skeptically

For public API, architecture, ownership/lifetime, backend seam, unsafe code or dependency changes, use a fresh-context review when practical. It should look for backend details leaking into Muntin APIs, inverted dependencies, acceptance weakened by tests, tests that bypass real dispatch, lifetime assumptions that hold for one backend only, speculative abstractions, and application verbosity added for internal convenience. It also checks that each guarantee the item newly documents (section 3) has executable evidence that fails without it. Review counts as evidence only when the reviewer inspected the diff and the verification results. If the full round produces fixes, one review scoped to those fixes follows; a material finding after that goes to the user before another round.

## 6. Finish an item

An item's pull request updates only the owners whose facts changed (section 7), in the same diff: `docs/ARCHITECTURE.md` when the current architecture changes (a revisit index row when the item pins fixtures), `docs/DX.md` when user-visible semantics change, `docs/SPEC.md` when a capability's status or the product scope changes, and `AGENT_PROGRESS.md` when the next action or an easy-to-miss current constraint changes. A typo, script or test-speed fix usually touches none of them. The item is complete when the pull request merges; `main` requires CI to pass first, so nothing is recorded after CI. Test counts, mutation lists, review findings and CI runs go in the pull request description; a new decision or amendment record names its pull request.

## 7. Where information lives

Each fact has one owner. Other documents link to it instead of restating it.

| Information | Owner |
|---|---|
| how to use Muntin: API, examples, user-visible semantics and diagnostics | `docs/DX.md` |
| how Muntin works now: invariants, registration, request handling, storage, backend seam, current limits, revisit index | `docs/ARCHITECTURE.md` |
| why: the decision, candidates, costs, measured premises, revisit conditions; the next production item's contract | `docs/history/architecture-decisions.md`, one record per decision or amendment |
| product scope: milestones, shipped and remaining capabilities, product boundaries, the M2 contract | `docs/SPEC.md` |
| evidence that an item was verified | its pull request |
| what to do next | `AGENT_PROGRESS.md` |
| behavior and invariants | tests, fixtures, `scripts/` and CI |
| upstream sources and the Flare pin | `docs/REFERENCES.md`, `pixi.lock` |

## 8. Stop at the requested boundary

When the active goal is satisfied, stop. Mention attractive follow-ups instead of implementing them.
