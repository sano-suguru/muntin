# Comparison with Flare alone decision (M3-079)

> **Current.** The candidates' order it confirmed is in [SPEC, "Remaining candidates"](../../SPEC.md#remaining-candidates).

Status: **decision, a standing constraint** (M3-079, pull request #180; issue [#139](https://github.com/sano-suguru/muntin/issues/139)). The evaluation, each application's outcomes, the cost table and the safety gaps are in the pull request. It replaces the freeze of pull request #166 ("Extensions while Muntin's value is evaluated", formerly in [deferrals](../deferrals.md)).

**Question and what settles it.** On the code of this decision (Mojo 1.1.0, Flare v0.12.0), does Muntin meet its long-term success criterion ([SPEC](../../SPEC.md#long-term-success-criterion)) against Flare alone, and what does its layer cost? It is the evaluation the freeze asked for, from which the owner decides whether to resume the candidates, reorder them or narrow Muntin's scope. Settled by the two applications written both ways (the users API, #102; the notes application, #167), run again on this code, each mistake's outcome sorted as rejected at build, right, loud or silent; the criterion is met when, in both applications, at least one of clearer, safer and more statically verifiable holds by the measures the pull request fixed before the runs, and none is reversed. The cost, the escape hatch, the backend seam and the safety checks' coverage and gaps are recorded with it.

**Choice: the criterion is met; the owner resumed the candidates in their order (2026-10-19).** Muntin's compiler rejected more of the mistakes written in both programs (5 of 7 against 2; 2 of 5 against 0), and the users API is shorter with fewer imported names. Neither program had fewer silent wrong answers, and the notes change removed more lines in Muntin. With a browser's request fields, Muntin costs 10–12.5 µs of CPU per HTTP/1.1 request over Flare (5–8 µs over h2c), about half of it in the header conversion entry 1 waits on. The next candidates address what the applications could not say: authentication in every handler, 400s without a cause, JSON mapped by hand. No cost budget was set: the criterion does not let benchmark results decide.

**Rejected.**
- Reordering: no property was reversed, and the order already puts the gaps found first.
- Narrowing Muntin's scope: the criterion is met in both applications.
- A cost budget: the owner chose none; a budget would be a new standing constraint here.

**Revisit when:**
- the comparison by new authors (#171) reports: its own gate ([deferrals](../deferrals.md#candidates-after-the-comparison-by-new-authors)) decides what follows it;
- the Flare pin or the Mojo version changes, or a second backend is built: run both applications again, and check that no file an application author writes had to change.

**Next production slice:** none. The rule is the candidates' order, owned by `docs/SPEC.md`, "Remaining candidates"; the next item is its first entry that can start.
