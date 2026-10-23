# Comparison by new authors decision (M3-086)

> **Current.** The candidates' order it kept is in [SPEC, "Remaining candidates"](../../SPEC.md#remaining-candidates).

Status: **decision, a standing constraint** (M3-086, pull request #197; issue [#171](https://github.com/sano-suguru/muntin/issues/171)). The kit is `bench/compare/authors/` and `scripts/compare_authors.py`; the runs and each task's results are in the pull request. It replaces the deferral that held the later candidates on this comparison (pull request #172).

**Question and what settles it.** On Mojo 1.1.0 and Flare v0.12.0, with M3-080, M3-083 and M3-085 shipped, does putting Muntin between an application and Flare reduce what an author new to both must remember and keep ([SPEC](../../SPEC.md#long-term-success-criterion))? Settled by the four tasks of #171 (an authenticated route, a DTO field, a planted persistence failure, a planted unexplained 400) on the notes application (#167), its Muntin side in today's API, each done three times per framework by fresh-context agents (Claude) in a workspace holding the program, the framework's documentation and source, the clients' contract and the task. Misses are hidden checks, written before any run, that fail on what an author delivered; places looked come from each run's transcript. Muntin reduces it when, on at least three tasks, its runs miss fewer checks, or as many with fewer places looked, and on none miss more.

**Finding: met, narrowly; fewer mistakes not shown.** All 24 runs passed every check. Muntin's runs looked in fewer places on three tasks (36 against 43, 41 against 51, 41 against 42) and as many on the fourth (38). The group's guard brought authentication with the new route, and the derived codec and the rejection report made the DTO change and the 400 a lookup in one reference page. The checks did not separate the frameworks, the authors are one model, and the concurrent runs disturbed each other.

**Choice: the owner resumed the candidates in their order (2026-10-23), as a judgment on that evidence.** No measure went Flare's way, and the effort fell clearly on two tasks.

**Rejected.**
- Reordering: the runs pointed at no candidate to move.
- Narrowing Muntin's scope: every task gained or tied.
- A harder comparison first (harder tasks or human authors): it would hold the candidates on a measure that did not discriminate here.

**Revisit when:**
- a comparison with checks that some runs fail, or with human authors, reports;
- the Flare pin or the Mojo version changes, or a second backend is built: `compare_authors.py selftest` passes again, with no file of the kit's Muntin program changed.

**Next production slice:** none. The rule is the candidates' order, owned by `docs/SPEC.md`, "Remaining candidates"; the next item is its first entry that can start.
