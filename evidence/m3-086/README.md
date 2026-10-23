# Evidence of the comparison by new authors (M3-086)

The runs of [#197](https://github.com/sano-suguru/muntin/pull/197), on a
branch that is not merged. The kit is this commit's
`bench/compare/authors/` and `scripts/compare_authors.py`.

`runs.tsv`: one run per line, `ID TASK PROGRAM N`. r01–r24 ran six at a
time; r01–r06 (the first `/me` batch) are set aside, since r01 stopped
other runs' servers. r25–r30 are their re-run, one at a time.

Each `rNN/` holds:

- `transcript.jsonl`: the author's prompt, every assistant message and tool
  call, and every tool result, as Claude Code recorded them, with what the
  harness attached (account, system prompt, tool listings) removed by
  `sanitize.py`. `places` prints the same on it as on the full transcript.
- `notes_PROGRAM.mojo`, `API.md`: what the author delivered. The rest of the
  workspace is what `compare_authors.py prepare TASK PROGRAM DIR` makes.
- `files.txt`: the workspace's paths as the run left them.
- `check.txt`: `compare_authors.py check` with this commit's checks;
  `check-first.txt` (r01–r24): with the checks written before the runs
  (commit `d56afaf`).
- `places.json`: `compare_authors.py places`.

To check a run's figures, from the repository root at this commit:

    python3 -I scripts/compare_authors.py selftest places
    python3 -I scripts/compare_authors.py places \
        evidence/m3-086/r01/transcript.jsonl /srv/runs/r01 evidence/m3-086/r01/files.txt

(`/srv/runs/rNN` was the run's workspace; with `files.txt` it need not
exist.) To score a delivery again, `prepare` its task and program into a
directory, copy the run's `notes_PROGRAM.mojo` and `API.md` into it, and run
`check` on it.
