# Comparison with Flare alone decision (M3-079)

> **Draft.** Only the question is written; the choice follows the evidence and the owner's decision on pull request #180.

Status: **decision** (M3-079, pull request #180; issue [#139](https://github.com/sano-suguru/muntin/issues/139)). The evaluation, its measurements and each application's results are in the pull request.

**Question and what settles it.** On the code of this decision (Mojo 1.1.0, Flare v0.12.0), does Muntin meet its long-term success criterion ([SPEC](../../SPEC.md#long-term-success-criterion)) against Flare alone, and what does its layer cost? It answers the evaluation that the freeze asks for ([deferrals](../deferrals.md#extensions-while-muntins-value-is-evaluated)), from which the owner decides whether to resume the candidates, reorder them or narrow Muntin's scope. Settled by the two applications written both ways (the users API, #102; the notes application, #167), run again on this code, each mistake's outcome sorted as rejected at build, right, loud or silent; the criterion is met when, in both applications, at least one of clearer, safer and more statically verifiable holds by the measures the pull request fixed before the runs, and none is reversed. The cost, the escape hatch, the backend seam and the safety checks' coverage and gaps are recorded with it.
