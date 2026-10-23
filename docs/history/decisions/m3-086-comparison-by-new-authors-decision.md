# Comparison by new authors decision (M3-086)

> **Current.** The candidates' order it kept is in [SPEC, "Remaining candidates"](../../SPEC.md#remaining-candidates).

Status: **decision, a standing constraint** (M3-086, pull request #197; issue [#171](https://github.com/sano-suguru/muntin/issues/171)). The kit is `bench/compare/authors/` and `scripts/compare_authors.py`; each run's checks, places and transcript are in the pull request and its comments. It replaces the deferral that held the later candidates on this comparison (pull request #172).

**Question and what settles it.** On Mojo 1.1.0 and Flare v0.12.0, with M3-080, M3-083 and M3-085 shipped, does putting Muntin between an application and Flare reduce what an author new to both must remember and keep ([SPEC](../../SPEC.md#long-term-success-criterion))? Settled by the four tasks of #171 (an authenticated route, a DTO field, a planted persistence failure, a planted unexplained 400) on the notes application (#167), its Muntin side in today's API, each done three times per framework by fresh-context agents (Claude) in a workspace holding the program, the framework's documentation and source, the clients' contract and the task. Misses are hidden checks that fail on what an author delivered; places looked come from each run's transcript. Muntin reduces it when, on at least three tasks, its runs miss fewer checks, or as many with fewer places looked, and on none miss more.

**Finding: not met.** No run missed a check, under the checks written before the runs or under those extended in review to the clients' contract and `API.md`. Muntin's runs looked in fewer places on two tasks (tag 36 against 43, journal 41 against 51), as many on the 400 (38), and more on `/me` (42 against 39, in a re-run one at a time that replaced a batch whose runs had disturbed each other; that batch had 41 against 42). The group's guard and the derived codec made the route and the DTO a lookup in one reference page; the measure did not separate the frameworks beyond that.

**Choice: the owner kept the candidates in their order (2026-10-23), as a judgment on that evidence.** No task went to Flare on misses, and its one lead in places is within the runs' spread (11 to 16 per run).

**Rejected.**
- Reordering: the runs pointed at no candidate to move.
- Narrowing Muntin's scope: no task showed Muntin costing more than Flare beyond that spread.
- A harder comparison first (checks that some runs fail, or human authors): it would hold the candidates on a measure that has not yet discriminated.

**Revisit when:**
- a comparison with checks that some runs fail, or with human authors, reports;
- the Flare pin or the Mojo version changes, or a second backend is built: `compare_authors.py selftest` passes again, with no file of the kit's Muntin program changed.

**Next production slice:** none. The rule is the candidates' order, owned by `docs/SPEC.md`, "Remaining candidates"; the next item is its first entry that can start.
