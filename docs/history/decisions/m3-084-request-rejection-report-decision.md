# Request rejection report decision (M3-084)

> **Current.** Not built yet: its "Next production slice" is M3-085.

Status: **decision** (M3-084, issue [#170](https://github.com/sano-suguru/muntin/issues/170)). Evidence: the pull request.

**Question and what settles it.** Muntin's 400s keep no cause: [M3-058](m3-058-dropped-error-report-decision.md) left them unreported, and [M3-059](m3-059-dropped-error-report-amendment.md) found that one can be a server-side fault. So an author finds why a request was refused only by reading Muntin's code: in #167 a misspelled member in a hand-written decoder answered every valid body 400 and logged nothing. Which 400s carry a report, through what Muntin-owned API, holding what of the request, and how does a conversion's server-side failure differ from bad input? Settled by every place `src/muntin` makes its 400, read in code; Mojo 1.1.0 probes of how a conversion could mark a failure as the server's; a scratch copy of production with the report passing `check.sh`, `test.sh` and `check_flare.sh` and a spike through `TestClient`; and a fresh-context review.
