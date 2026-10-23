# Comparison by new authors decision (M3-086)

> **Draft.** Only the question is written; the choice follows the evidence and the owner's decision on its pull request.

Status: **decision** (M3-086, its pull request; issue [#171](https://github.com/sano-suguru/muntin/issues/171)). The runs, their logs and each task's results are in the pull request.

**Question and what settles it.** On the code of this decision (Mojo 1.1.0, Flare v0.12.0, with M3-080, M3-083 and M3-085 shipped), does putting Muntin between an application and Flare reduce what an author new to both must remember and keep ([SPEC](../../SPEC.md#long-term-success-criterion))? It is the comparison the [deferral](../deferrals.md#candidates-after-the-comparison-by-new-authors) holds the later candidates on, from which the owner decides whether to resume them, reorder them or narrow Muntin's scope.

Settled by runs of the four tasks of #171 on the notes application (#167), written both ways, the Muntin program first rewritten with today's API (guarded groups, derived JSON codecs, rejection reports) with every answer of its scenario unchanged:

1. add an authenticated route;
2. add a field to the note;
3. fix a persistence failure planted in both programs (a failed journal write answered as success);
4. fix an unexplained 400 planted in both programs (a JSON member the client and the program name differently).

Each run is one author, one task, one program, starting fresh in a workspace `scripts/compare_authors.py` prepares: the program, its framework's documentation and source, the clients' contract (`API.md`) and the task's text, the same for both programs, and not this record, earlier comparisons or the checks below. The authors are fresh-context agents (Claude), three runs per task and program, the six runs of a task at once; that they are not human, share one model and are shown this repository's agent instructions (`AGENTS.md`, which name both frameworks and no API) is a limit of the result. Recorded per run, by measures fixed here: time (wall clock, turns and tool calls); places looked (distinct files and directories of the workspace read, searched or listed, from the run's transcript); misses (the hidden checks, `bench/compare/authors/checks/`, written before any run, that fail on the delivered program: the new route refuses a missing or wrong token, the success status, the JSON member names, data kept across a restart, a write failure answered as an error with its cause on standard error, and no other answer of the scenario changed). A run that reads outside its workspace is void and run again.

Muntin reduces what an author must remember on this sample when, on at least three of the four tasks, its runs miss fewer checks than Flare's, or as many with fewer places looked, and on no task miss more. Every run is reported, whichever way it goes.
