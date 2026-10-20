# Comparison with Flare alone decision (M3-079)

> **Current.** The candidates' order it kept is in [SPEC, "Remaining candidates"](../../SPEC.md#remaining-candidates).

Status: **decision, a standing constraint** (M3-079, pull request #180; issue [#139](https://github.com/sano-suguru/muntin/issues/139)). The evaluation is in the pull request. It replaces the freeze of pull request #166 ("Extensions while Muntin's value is evaluated", formerly in [deferrals](../deferrals.md)).

**Question and what settles it.** On the code of this decision (Mojo 1.1.0, Flare v0.12.0), does Muntin meet its long-term success criterion ([SPEC](../../SPEC.md#long-term-success-criterion)) against Flare alone, and what does its layer cost? It is the evaluation the freeze asked for, before the owner decides how to go on. Evidence: the users API (#102) and the notes application (#167), written both ways and run again, each planted mistake's outcome sorted by measures fixed before the runs; the cost; the safety checks' coverage and gaps.

**Finding: on this sample Muntin's compiler catches more call mistakes; the criterion is not shown.** Of the mistakes in both programs, Muntin's rejected 4 of 6 against Flare's 2 (users; two values declared in the other order, right in Flare, is not counted) and 2 of 5 against 0 (notes). Neither program had fewer silent wrong answers. Muntin's programs are shorter, which does not count what a 400 without its cause costs to diagnose. The measures give a direction, not a material difference: two small applications, one author, measures written knowing earlier results. Not shown either: surviving a toolchain or backend change (one Flare update, none of Mojo, no second backend). Known debts: `State` judges borrowing by a type's name and admits types that read freed memory; a failed conversion is a 400 whose cause is dropped.

**Choice: the owner ended the freeze and resumed the candidates in their order (2026-10-19), as a judgment under that uncertainty.** Entries 2 to 4 address what the applications could not say: authentication in every handler, a 400's cause, hand-mapped JSON. The owner accepted the cost as a trade-off and set no budget: with a browser's request fields, 10–12.5 µs of CPU per HTTP/1.1 request over Flare (5–8 µs over h2c), about half of it in the header conversion entry 1 waits on. The comparison by new authors (#171) is the next test of the criterion.

**Rejected.**
- Reordering: no property went Flare's way, and the order already puts the gaps found first.
- Narrowing Muntin's scope now: the sample shows an advantage, if not a material one yet.
- Claiming the criterion met: the evidence does not reach "materially".

**Revisit when:**
- the comparison by new authors reports ([its gate](../deferrals.md#candidates-after-the-comparison-by-new-authors));
- the Flare pin or the Mojo version changes, or a second backend is built: run both applications again, and check that no file an application author writes had to change.

**Next production slice:** none. The rule is the candidates' order, owned by `docs/SPEC.md`, "Remaining candidates"; the next item is its first entry that can start.
