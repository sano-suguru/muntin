# Muntin development loop

## 1. Orient

Check `git status` and recent commits, and run the cheapest relevant check. The item is the one the user asked for; without one, the first entry of `docs/SPEC.md`, "Remaining candidates". Read the document that owns what the next change touches (section 7). Do not re-plan the project when the repository state is coherent.

## 2. Pick one increment

Take one coherent item that can be verified on its own: one observable outcome, a bounded file set, a real executable check, and no unrelated future work. For an uncertain Mojo feature, make a small compilation experiment before designing around it.

Where an item's contract is written depends on its kind, and nowhere else:

| Item | Its contract | Written when |
|---|---|---|
| decision (a design question, settled with evidence suited to it: existing records and pull requests where they suffice, spikes and fixtures under `tests/` where compiler or runtime behavior must be measured; `src/muntin` unchanged) | its pull request first: the question and what would settle it. Then, if it chooses to build, its new record in `docs/history/architecture-decisions.md` with the choice and one "Next production slice"; if it sets a standing constraint, its record (below); if it defers, the `docs/SPEC.md` lines below | the question and settling condition before any measurement; the choice and next action after the evidence |
| production (implements a decided slice) | the decision record's "Next production slice", as written | already, by the decision item |
| production that cannot follow its slice as written | an amendment record: the delta to the slice, why, and the invariant or compatibility boundary it affects | before the change merges; a new design question is a new decision item, not an amendment |
| fix, behavior-preserving refactor, tooling or docs with no design question | the pull request | with the pull request |

A decision record has five parts, in this order: the question and what would settle it; the choice and why, in a few sentences; each rejected candidate in one line, with why; its "Revisit when" conditions; and its "Next production slice". Keep it under about 8 KB. Measurements, compiler output, candidate-by-candidate comparisons, test counts and review findings go in the pull request, which the record names. Records written before this rule stay as they are.

A standing constraint, a decision whose choice is a rule that later items must follow (a budget, a policy) rather than something to build, gets a record with the same five parts; its "Next production slice" says none, names the document that owns the rule, and the pull request writes the rule there.

A decision whose choice is to build nothing now (an explicit deferral of a candidate, no "Next production slice") gets no record: its contract is one or two lines under its candidate in `docs/SPEC.md`, "Remaining candidates": the choice, why, the revisit condition and its pull request. A test or fixture it adds to pin today's behavior names that pull request in its opening comment, and so does its revisit index row.

A product item, decision or production, gets a milestone ID (`M3-017`) where it is first named: a decision record's title or its "Next production slice". A process or tooling decision gets none unless `docs/SPEC.md` tracks it as milestone work. `docs/SPEC.md` refers to it; nothing else tracks it.

## 3. Verify with the strongest available oracle

A change is not complete because the code looks plausible. Use, as applicable: a focused executable test for the changed behavior, the broader suites, build/type/static checks, end-to-end execution, architecture/dependency checks, and `git diff --check`. A syntax-only check, a command that failed to start, or a skipped test is not passing evidence.

- `./scripts/check.sh`: toolchain version, formatting, architecture boundary, unsafe confinement, package and example builds, the library-only spike drivers, and every must-not-build and must-build fixture under `tests/` (in parallel; reports in file order). `CHECK_SHARD=I/N` builds only every N-th fixture, starting at the I-th, and still runs every other step; CI uses it. It does not build `tests/test_*.mojo`.
- `./scripts/test.sh [FILE...]`: builds each `tests/test_*.mojo` (or the named files) with `--Werror` in parallel, then runs them one at a time.
- `SANITIZE=address ./scripts/test.sh [FILE...]`: the same, built with Mojo's AddressSanitizer (`mojo build --sanitize address`). A heap use-after-free or double free, and on Linux a leak at exit (forced on whatever `ASAN_OPTIONS` says, with `LSAN_OPTIONS` unset so no suppression from the environment applies; reports go to stderr whatever `log_path` says), fails the file even when every assertion passed. Before building any test it builds and runs the positive controls in `tests/sanitizer_controls`, listed by name in the script, each of which must fail with a sanitizer report of the kind its `# Expected report: ` line names, so a toolchain whose sanitizer stops seeing these errors, or a deleted control, stops the run there; the leak control runs on Linux only, the one platform where leak detection is verified for this toolchain. A control proves only that the sanitizer sees that error in that program. It is the runtime check of the unsafe storage (`_Erased`, `_Shared`) on the paths `tests/test_*.mojo` run, not of the Flare adapter (`check_flare.sh` is unchanged), and not a proof: an error on a path no test runs, or an access the compiler removed, goes unseen. The ownership oracles in `tests/test_handler_storage.mojo` and `tests/test_state.mojo` count live values, which cannot see a leaked header or a read of a freed one. CI does not run it; run it locally on Linux when a change touches `src/muntin/_handler_storage.mojo` or how `App` or `State` hold it.
- `./scripts/check_flare.sh`: the Flare adapter, its `Server` tests and localhost round trips, the serving must-not-build fixtures and the serving example's build, in the `flare` environment; it also builds `bench/overhead/bench_adapter.mojo` and, on Linux, runs its allocation count once, so that the counter `bench_overhead.sh` uses keeps working.

`./scripts/bench_routing.sh [RUNS] [N...]` is a measurement, not a check, and CI does not run it: routing cost by route count, Muntin against Flare alone (`bench/routing/bench_routing.mojo` says what it measures). Its results go in the pull request that relies on them, with the machine and the versions the script prints.

`./scripts/bench_headers.sh [RUNS] [SECONDS] [ROUNDS]` is a measurement too, and CI does not run it: the Flare adapter's request header conversion by header shape, in process, beside the rebuild M3-066 rejected, their runs alternating (`bench/headers/bench_headers.mojo` says what it measures), then that rebuild's tests (`bench/headers/write_to_pieces.mojo`), then over HTTP/1.1 loopback against a Muntin `Server`, the same with its conversion routed through that rebuild, and Flare's `HttpServer` alone, in turn for ROUNDS rounds: one request at a time, requests arriving at a fixed rate to a route that reads the fields, and four connections sending the largest shapes while bare requests measure latency, closed and open loop (`bench/headers/load.py`); each server's peak RSS and the medians over the rounds, which fail unless every server reported every case in every round. The loopback servers build against any commit that has `to_muntin_headers`, so a change is measured at its base and at its head. Its results go in the pull request that relies on them, with the versions the script prints.

`./scripts/compare_dx.sh` is a measurement too, and CI does not run it: one small API written with Muntin and against Flare alone (`bench/compare/`), compared by code size, by the answers to the same requests, and by what each does with the same planted mistakes (whether it still builds, the compiler's message, or what the mistaken program answers). Its results go in the pull request that relies on them, with the versions the script prints.

`./scripts/bench_overhead.sh` is a measurement too, and CI does not run it (only the smoke run above): what Muntin costs on top of Flare, one application written with Muntin and against Flare alone (`bench/overhead/`), built alike. It times one request in process, without the network, by request header count and body size (`bench/overhead/bench_adapter.mojo` says what it measures), counts the same requests' allocations (Linux with glibc and a C compiler only; `bench/overhead/count_alloc.c` says what it counts), then serves each implementation on loopback and loads it with wrk: requests per second, latency p50 and p99, errors and the server's peak resident memory since it started, by worker count, middleware, endpoint and connection count, after checking that both put the same answer on the wire, `ROUNDS` times with the implementations' order reversed in every other round, and summarizes the rounds, those with errors apart. Its results go in the pull request that relies on them, with the machine and the versions the script prints.

`./scripts/bench_hol.sh [RUNS] [SLOW_MS]` is a measurement too, and CI does not run it: what one handler blocking its thread for `SLOW_MS` does to the other requests of the process, `Server` against Flare alone, over HTTP/1.1 and h2c, by worker count, listener form and idle timeout, with a control that holds nothing, how each spreads kept-open connections over its workers, and whether `Server` answers a new connection while one handler fewer than its workers, and as many, are held, failing only on an answer that is not `200` or a hold it could not set up, not on which way `/health` went (the script's header and `bench/hol/hol_client.py` say what is measured). It runs on Linux only and needs `python3` beside the `flare` environment. Its results go in the pull request that relies on them, with the machine and the versions the script prints.

`./scripts/run_origin_gaps.sh` is a measurement too, and CI does not run it: it builds the known gaps that erase a value borrowing a dropped local (`tests/context_known_gaps/erasure_drops_origin.mojo` and `tests/state_known_gaps/state_borrows_dropped_local*.mojo`) with AddressSanitizer, runs them, and requires the report each file's `# Expected report: ` line names. `check.sh` only builds them, which shows that the compiler accepts them, not what running them does. A pull request that changes the Mojo version runs it and gives its result; a file that stops reporting reopens the decision its revisit index row names.

A must-not-build fixture states its expected diagnostic on a line starting `# Expected diagnostic (checked by scripts/check.sh): `; `scripts/build_one.sh` reads it.

CI runs all three scripts on every pull request that changes code (section 4); a passing `ci-ok` on the final HEAD is the evidence that they pass, and running them locally first is the author's choice. Beyond that, a production item adds the following ([why](history/architecture-decisions.md#production-verification-policy-decision)):

- Tests and fixtures for the new behavior. Each behavior, diagnostic or invariant that the item newly documents as guaranteed in `docs/DX.md` or `docs/ARCHITECTURE.md` needs executable evidence that fails if the claim stops being true. Rationale, costs and descriptions of the current implementation are not such claims. Where no test or fixture plainly targets a claim, a mutation planted in a scratch copy shows whether one does; nothing counts mutations.
- Each new must-not-build fixture that pins the change is also built against the base's `src`, and the pull request says whether it fails there with the same text. One that does is a regression pin, not evidence for the change.
- A comparison of every existing fixture's whole normalized compiler output against the base, when the change can alter compiler output outside the checked expected texts: overload resolution or the candidate set, the signatures candidate notes print, the instantiation or call-chain frames, or the compiler itself. Examples: a `get` or `post` overload added or removed, an overload's signature or `where` clause, `_check`'s parameters or the call chain to it, the Mojo version. A rule's branch or message (`_kind`, `_get_rule`, `_post_rule`, the text in `_check`) changes only the message line, which the expected texts check.
- When the change can reach the wire (`adapters/`, `compat/`, the `Request`, `Response` or `Headers` types or their conversion, how `App.handle` reads the request or builds the response, a limit or status that depends on the backend): loopback coverage of the changed wire behavior, preferably by extending an existing case in `adapters/flare/test_localhost_roundtrip.mojo`, and by a new case only where none can observe it. CI's `flare` job runs that coverage; a local `check_flare.sh` run before pushing is not required ([why](history/architecture-decisions.md#local-flare-run-decision)). The adapter converts every request the same way whatever the route, so a new handler shape proven through `App.handle` needs no loopback case.

A "Next production slice" may require more only for a concrete risk this list does not cover, and names that risk. Such a check belongs to that item; it becomes a requirement for later items only if this section is changed to say so.

## 4. CI and merging

CI runs on pull requests only. `verify` (`check.sh` with `git diff --check` as two jobs that each build half of the fixtures, and `test.sh` as a third) and `flare` run on ubuntu-latest and macos-latest, except when every changed file is under `docs/` or ends in `.md`; then both are skipped. `ci-ok` passes only when both ran and passed, or both were skipped for a docs-only change; it is the one required status check for `main`, where a ruleset also requires a pull request that is up to date with `main`. A new push cancels the running checks; nothing reruns after a merge. Each `verify` and `flare` job restores and saves Mojo's compile cache (`.pixi/envs/<env>/share/max/cache/.mojo_cache`), never the `flare` environment itself. A pull request cannot read another's cache, so its first run builds cold; and the cache holds builds per target CPU, which defaults to the runner's, so a run on a CPU model the pull request has not run on yet also builds cold. Each job prints its CPU model.

Dependabot (`.github/dependabot.yml`) updates only the GitHub Actions in `.github/workflows/`, weekly: minor and patch bumps in one pull request, each major bump in its own. pixi dependencies stay manual: Dependabot's `conda` ecosystem does not read `pixi.toml` or `pixi.lock` ([supported ecosystems](https://docs.github.com/en/code-security/dependabot/ecosystems-supported-by-dependabot/supported-ecosystems-and-repositories)), and the Mojo version and the Flare pin change only with the owner's approval. Dependabot does not touch the `pixi-version` input of `prefix-dev/setup-pixi`; when a `setup-pixi` bump fails, check that pin first.

## 5. Review important boundaries skeptically

For public API, architecture, ownership/lifetime, backend seam, unsafe code or dependency changes, use a fresh-context review when practical. It should look for backend details leaking into Muntin APIs, inverted dependencies, acceptance weakened by tests, tests that bypass real dispatch, lifetime assumptions that hold for one backend only, speculative abstractions, and application verbosity added for internal convenience. It also checks that each guarantee the item newly documents (section 3) has executable evidence that fails without it. Review counts as evidence only when the reviewer inspected the diff and the verification results. If the full round produces fixes, one review scoped to those fixes follows; a material finding after that goes to the user before another round.

## 6. Finish an item

An item's pull request updates only the owners whose facts changed (section 7), in the same diff: `docs/ARCHITECTURE.md` when the current architecture changes (a revisit index row when the item pins fixtures: the pinned paths and a link to the decision record, or to the pull request for an explicit deferral without a record), `docs/DX.md` when user-visible semantics change, and `docs/SPEC.md` when a capability's status, the product scope or the candidates' order changes (one table row per capability, naming it and linking its decision, never restating its semantics). There is no separate handoff file: a fact that is easy to miss about the current code goes in `docs/ARCHITECTURE.md` or in a comment beside the code, once. A typo, script or test-speed fix usually touches none of them. The item is complete when the pull request merges; `main` requires CI to pass first, so nothing is recorded after CI. Test counts, mutation lists, review findings and CI runs go in the pull request description; a new decision or amendment record names its pull request.

## 7. Where information lives

Each fact has one owner. Other documents link to it instead of restating it.

| Information | Owner |
|---|---|
| how to use Muntin: API, examples, user-visible semantics and diagnostics | `docs/DX.md` |
| how Muntin works now: invariants, registration, request handling, storage, backend seam, current limits, revisit index | `docs/ARCHITECTURE.md` |
| why: the decision, candidates, costs, measured premises, revisit conditions; the next production item's contract | `docs/history/architecture-decisions.md`, one record per decision or amendment |
| product scope: milestones, shipped and remaining capabilities, product boundaries, the M2 contract | `docs/SPEC.md` |
| evidence that an item was verified | its pull request |
| what to do next | the user's request; otherwise the first entry of `docs/SPEC.md`, "Remaining candidates" |
| behavior and invariants | tests, fixtures, `scripts/` and CI |
| upstream sources and the Flare pin | `docs/REFERENCES.md`, `pixi.lock` |

## 8. Stop at the requested boundary

When the active goal is satisfied, stop. Mention attractive follow-ups instead of implementing them.
