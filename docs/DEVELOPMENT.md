# Muntin development loop

## 1. Orient

Check `git status` and recent commits, and run the cheapest relevant check. The item is the one the user asked for; without one, the first entry of `docs/SPEC.md`, "Remaining candidates". Read the document that owns what the next change touches (section 7). Do not re-plan the project when the repository state is coherent.

## 2. Pick one increment

Take one coherent item that can be verified on its own: one observable outcome, a bounded file set, a real executable check, and no unrelated future work. For an uncertain Mojo feature, make a small compilation experiment before designing around it.

Where an item's contract is written depends on its kind, and nowhere else:

| Item | Its contract | Written when |
|---|---|---|
| decision (a design question, settled with evidence suited to it: existing records and pull requests where they suffice, spikes and fixtures under `tests/` where compiler or runtime behavior must be measured; `src/muntin` unchanged) | its pull request first: the question and what would settle it. Then, if it chooses to build, its new record, a file in `docs/history/decisions/` listed in `docs/history/architecture-decisions.md`, with the choice and one "Next production slice"; if it sets a standing constraint, its record (below); if it defers, its entry in `docs/history/deferrals.md` (below) | the question and settling condition before any measurement; the choice and next action after the evidence |
| production (implements a decided slice) | the decision record's "Next production slice", as written | already, by the decision item |
| production that cannot follow its slice as written | an amendment record: the delta to the slice, why, and the invariant or compatibility boundary it affects | before the change merges; a new design question is a new decision item, not an amendment |
| fix, behavior-preserving refactor, tooling or docs with no design question | the pull request | with the pull request |

A decision record has five parts, in this order: the question and what would settle it; the choice and why, in a few sentences; each rejected candidate in one line, with why; its "Revisit when" conditions; and its "Next production slice". Keep it to 1–3 KB, about one screen: a reader should learn what was chosen and when to look again without scrolling. Measurements, compiler output, candidate-by-candidate comparisons, test counts and review findings go in the pull request, which the record names. Records written before this rule stay as they are.

Each record opens with its state (current, superseded or withdrawn, as `docs/history/architecture-decisions.md` defines them), the later records that changed part of it, and where the behavior it decided is described now. A new record is current. The pull request of a record that supersedes, withdraws or changes part of an earlier one updates that record's opening lines and its row in `docs/history/architecture-decisions.md`. A record's body is not rewritten, except to repoint a reference whose target moved, which the pull request lists.

A standing constraint, a decision whose choice is a rule that later items must follow (a budget, a policy) rather than something to build, gets a record with the same five parts; its "Next production slice" says none, names the document that owns the rule, and the pull request writes the rule there.

A decision whose choice is to build nothing now (an explicit deferral of a candidate, no "Next production slice") gets no record: its contract is a short entry in `docs/history/deferrals.md`: the choice, why, the revisit condition and its pull request. Its revisit condition binds later items, so it is versioned with the code; the candidate's GitHub issue holds the discussion and links the entry. A test or fixture it adds to pin today's behavior names that pull request in its opening comment, and so does its revisit index row.

A product item, decision or production, gets a milestone ID (`M3-017`) where it is first named: a decision record's title or its "Next production slice". A process or tooling decision gets none unless `docs/SPEC.md` tracks it as milestone work. `docs/SPEC.md` refers to it; nothing else tracks it.

## 3. Verify with the strongest available oracle

A change is not complete because the code looks plausible. Use, as applicable: a focused executable test for the changed behavior, the broader suites, build/type/static checks, end-to-end execution, architecture/dependency checks, and `git diff --check`. A syntax-only check, a command that failed to start, or a skipped test is not passing evidence.

- `./scripts/check.sh`: toolchain version, formatting, architecture boundary, unsafe confinement, the documents' checks (`./scripts/check_docs.sh`, below), the head-of-line client's response checks (`bench/hol/test_hol_client.py`, Python standard library only), package and example builds, the library-only spike drivers, and every must-not-build and must-build fixture under `tests/` (in parallel; reports in file order). `CHECK_SHARD=I/N` builds only every N-th fixture, starting at the I-th, and still runs every other step; CI uses it. It does not build `tests/test_*.mojo`. A must-not-build fixture states its expected diagnostic on a line starting `# Expected diagnostic (checked by scripts/check.sh): `; `scripts/build_one.sh` reads it.
- `./scripts/check_docs.sh`: that every Mojo example in `README.md`, `docs/GUIDE.md` and `docs/reference/` is the text of the file it names (`scripts/check_doc_examples.py`); that each document read routinely is within its size budget (section 7), every relative link and its anchor in a Markdown file resolve, and every repository path in backticks in the current documents (not `docs/history/`) and every `docs/` page a code or script file names exists, as does each section cited by path and quoted heading or number (`scripts/check_docs.py`). Each checker has its own test (`scripts/test_check_*.py`). Python standard library only; no pixi or Mojo.
- `./scripts/test.sh [FILE...]`: builds each `tests/test_*.mojo` (or the named files) with `--Werror` in parallel, then runs them one at a time.
- `SANITIZE=address ./scripts/test.sh [FILE...]`: the same, built with Mojo's AddressSanitizer. A heap use-after-free or double free, and on Linux a leak at exit, fails the file even when every assertion passed. It first runs the positive controls in `tests/sanitizer_controls`, each of which must fail with the report its `# Expected report: ` line names, so a toolchain whose sanitizer stops seeing these errors stops the run there (the script's header has the details). It is the runtime check of the unsafe storage (`_Erased`, `_Shared`) on the paths `tests/test_*.mojo` run, not of the Flare adapter, and not a proof: an error on a path no test runs, or an access the compiler removed, goes unseen. The ownership oracles in `tests/test_handler_storage.mojo` and `tests/test_state.mojo` count live values, which cannot see a leaked header or a read of a freed one. CI does not run it; run it locally on Linux when a change touches `src/muntin/_handler_storage.mojo` or how `App` or `State` hold it.
- `./scripts/check_flare.sh`: the Flare adapter, its `Server` tests and localhost round trips, the serving must-not-build fixtures and the serving example's build, in the `flare` environment; it also builds `bench/overhead/bench_adapter.mojo` and, on Linux, runs its allocation count once, so that the counter `bench_overhead.sh` uses keeps working.

The measurements below are not checks, and CI does not run them. Each script's header says what it measures, its arguments and its platforms; its results go in the pull request that relies on them, with the machine and the versions it prints.

| Script | Measures |
|---|---|
| `./scripts/bench_routing.sh` | routing cost by route count, Muntin against Flare alone |
| `./scripts/bench_headers.sh` | the adapter's request header conversion by header shape, in process and over loopback |
| `./scripts/compare_dx.sh` | one small API written with Muntin and against Flare alone: code size, answers, planted mistakes |
| `python3 -I scripts/compare_notes.py` | the same for an application with stored data, users, a failing journal, start-up settings and one change |
| `./scripts/bench_overhead.sh` | what Muntin costs on top of Flare: time, allocations, throughput, latency, memory |
| `./scripts/bench_hol.sh`, `bench/hol/spread/run_spread.sh` | what one blocking handler does to the other requests; how kept-open connections spread over workers (Linux) |
| `./scripts/run_origin_gaps.sh` | that the known gaps erasing a value which borrows a dropped local still read freed memory under AddressSanitizer |

`bench_headers.sh`'s client expects the 431 past `Server.bind`'s 100-field limit (M3-067), so a base without that limit is measured with that base's own revision of the script. A pull request that changes the Mojo version runs `run_origin_gaps.sh` and gives its result; a file that stops reporting reopens the decision its revisit index row names.

CI runs all three check scripts on every pull request that changes code (section 4); a passing `ci-ok` on the final HEAD is the evidence that they pass, and running them locally first is the author's choice. Beyond that, a production item adds the following ([why](history/decisions/production-verification-policy-decision.md)):

- Tests and fixtures for the new behavior. Each behavior, diagnostic or invariant that the item newly documents as guaranteed in `docs/reference/` or `docs/ARCHITECTURE.md` needs executable evidence that fails if the claim stops being true. Rationale, costs and descriptions of the current implementation are not such claims. Where no test or fixture plainly targets a claim, a mutation planted in a scratch copy shows whether one does; nothing counts mutations.
- Each new must-not-build fixture that pins the change is also built against the base's `src`, and the pull request says whether it fails there with the same text. One that does is a regression pin, not evidence for the change.
- A comparison of every existing fixture's whole normalized compiler output against the base, when the change can alter compiler output outside the checked expected texts: overload resolution or the candidate set, the signatures candidate notes print, the instantiation or call-chain frames, or the compiler itself. Examples: a `get` or `post` overload added or removed, an overload's signature or `where` clause, `_check`'s parameters or the call chain to it, the Mojo version. A rule's branch or message (`_kind`, `_get_rule`, `_post_rule`, the text in `_check`) changes only the message line, which the expected texts check.
- When the change can reach the wire (`adapters/`, `compat/`, the `Request`, `Response` or `Headers` types or their conversion, how `App.handle` reads the request or builds the response, a limit or status that depends on the backend): loopback coverage of the changed wire behavior, preferably by extending an existing case in `adapters/flare/test_localhost_roundtrip.mojo`, and by a new case only where none can observe it. CI's `flare` job runs that coverage; a local `check_flare.sh` run before pushing is not required ([why](history/decisions/local-flare-run-decision.md)). The adapter converts every request the same way whatever the route, so a new handler shape proven through `App.handle` needs no loopback case.

A "Next production slice" may require more only for a concrete risk this list does not cover, and names that risk. Such a check belongs to that item; it becomes a requirement for later items only if this section is changed to say so.

## 4. CI and merging

CI runs on pull requests only. `verify` (`check.sh` with `git diff --check` as two jobs that each build half of the fixtures, and `test.sh` as a third) and `flare` run on ubuntu-latest and macos-latest, except when every changed file is under `docs/` or ends in `.md`; then both are skipped. `docs` runs `check_docs.sh` on ubuntu-latest for every pull request, docs-only ones included. `ci-ok` passes only when `docs` passed and the other two both ran and passed, or both were skipped for a docs-only change; it is the one required status check for `main`, where a ruleset also requires a pull request that is up to date with `main`. A new push cancels the running checks; nothing reruns after a merge. Each `verify` and `flare` job restores and saves Mojo's compile cache (`.pixi/envs/<env>/share/max/cache/.mojo_cache`), never the `flare` environment itself. A pull request cannot read another's cache, so its first run builds cold; and the cache holds builds per target CPU, which defaults to the runner's, so a run on a CPU model the pull request has not run on yet also builds cold. Each job prints its CPU model.

Dependabot (`.github/dependabot.yml`) updates only the GitHub Actions in `.github/workflows/`, weekly: minor and patch bumps in one pull request, each major bump in its own. pixi dependencies stay manual: Dependabot's `conda` ecosystem does not read `pixi.toml` or `pixi.lock` ([supported ecosystems](https://docs.github.com/en/code-security/dependabot/ecosystems-supported-by-dependabot/supported-ecosystems-and-repositories)), and the Mojo version and the Flare pin change only with the owner's approval. Dependabot does not touch the `pixi-version` input of `prefix-dev/setup-pixi`; when a `setup-pixi` bump fails, check that pin first.

## 5. Review important boundaries skeptically

For public API, architecture, ownership/lifetime, backend seam, unsafe code or dependency changes, use a fresh-context review when practical. It should look for backend details leaking into Muntin APIs, inverted dependencies, acceptance weakened by tests, tests that bypass real dispatch, lifetime assumptions that hold for one backend only, speculative abstractions, and application verbosity added for internal convenience. It also checks that each guarantee the item newly documents (section 3) has executable evidence that fails without it. Review counts as evidence only when the reviewer inspected the diff and the verification results. If the full round produces fixes, one review scoped to those fixes follows; a material finding after that goes to the user before another round.

## 6. Finish an item

An item's pull request updates, in the same diff, only what its kind of change needs:

| Change | Updates |
|---|---|
| public API or user-visible behavior | the reference page that owns it, with a runnable example that names the test running it (`tests/test_reference_examples.mojo` when no feature test runs it as written) and says what it leaves out (`...`, names defined on another page) and what that test changes; the guide only when the common case changes, with `tests/test_guide.mojo`. The example is that test's text, marked there by `# example: <id>` and `# example: end` and named by the `<!-- example: ... -->` line above the block (the format is in `scripts/check_doc_examples.py`). An example whose answers a test checks builds its `App` in a function that returns it (`make_app`), and the test sends its requests to that `App`, never to routes it registers again; the serving examples that bind a fixed port are only built. `check.sh` fails when they differ, but CI skips it for a pull request that changes only documentation (section 4), so run `python3 -I scripts/check_doc_examples.py` before pushing one |
| structure, ownership or a safety boundary | `docs/ARCHITECTURE.md`, or the invariant's comment beside the code with `docs/ARCHITECTURE.md` naming it and linking there (one wording, one owner); a revisit index row when it pins fixtures (the paths and a link to the record, or to the pull request for a deferral) |
| a long-term choice | a short decision record (section 2) |
| a capability's status, the product scope or the candidates' order | `docs/SPEC.md`: one table row per capability, naming it and linking its decision, never restating its semantics |
| an ordinary bug fix | only the existing text the fix makes wrong |
| a measurement | the pull request |
| a deferral (a decision to build nothing now) | its entry in `docs/history/deferrals.md`, linked from the candidate's issue |
| a future idea or its discussion | a GitHub issue, not a document |

There is no separate handoff file: a fact that is easy to miss about the current code goes in `docs/ARCHITECTURE.md` or in a comment beside the code, once. A typo, script or test-speed fix usually touches no document. The item is complete when the pull request merges; `main` requires CI to pass first, so nothing is recorded after CI. Test counts, mutation lists, review findings and CI runs go in the pull request description; a new decision or amendment record names its pull request.

## 7. Where information lives

Each fact has one owner; other documents link to it instead of restating it. The owner is chosen by who reads it and when, because a document read for one purpose grows unreadable when it also carries another's facts: a user looking up a rule should not wade through why it was chosen, and a contributor checking an invariant should not wade through tutorials.

| Document | Reader, and when | What goes there | What does not |
|---|---|---|---|
| `README.md` | anyone deciding whether to try Muntin | what it is, how to run it, its maturity, links | API rules, design argument |
| `docs/GUIDE.md` | an application author starting out | the common case of each feature, short, with links to the reference; the most serious limits, briefly | every rule, status and diagnostic; history |
| `docs/reference/` | an application author looking up one rule | the current API: accepted shapes, statuses, diagnostics, runnable examples, one page per topic | why, alternatives, progress, plans |
| `docs/ARCHITECTURE.md` | a contributor changing Muntin | how it works now: invariants, request handling, storage, the backend seam, current limits, the revisit index | user tutorials, completed plans, the history of a choice |
| `docs/history/architecture-decisions.md` and `docs/history/decisions/` | someone asking why, or what to build next | the list of records with each one's state; one short record per decision or amendment, one file each; the next production item's contract; in `deferrals.md`, the contract of each deferral | measurements and review logs (the pull request) |
| `docs/SPEC.md` | someone choosing the next item | product scope, milestones, shipped capabilities, the top remaining candidates in order | candidate details (the issue), semantics (the reference) |
| `docs/DEVELOPMENT.md` | a contributor finishing an item | how to verify, CI, what to update, this table | product or API facts |
| GitHub issues | anyone planning | each remaining candidate or future design target, its details and discussion | anything already shipped; a constraint later items must follow (a revisit condition), which needs a versioned record |
| pull requests | the reviewer, and later an auditor | evidence: measurements, compiler output, test counts, review findings | rules later items must follow |
| code comments | whoever edits that code | the invariant the code must keep, beside it | narratives, plans |

Each document read routinely has a size budget in `scripts/check_docs.py`, and `check_docs.sh` fails when one grows past it. The budget is a prompt to check each new fact against this table and move what belongs elsewhere; it is never a reason to drop a constraint, exception or safety condition. When the facts belong where they grew, the pull request raises the budget and says why. In the same way, a change that reduces a document is reviewed by whether its constraints, exceptions and safety conditions survive, not by how much it removed.

Other owners: behavior and invariants are also owned by tests, fixtures, `scripts/` and CI; upstream sources and the Flare pin by `docs/REFERENCES.md` and `pixi.lock`; what to do next by the user's request, otherwise the first entry of `docs/SPEC.md`, "Remaining candidates". A serious limit may be repeated briefly in the README or the guide, linking its owner, so that a reader who stops there still sees it.

## 8. Stop at the requested boundary

When the active goal is satisfied, stop. Mention attractive follow-ups instead of implementing them.
