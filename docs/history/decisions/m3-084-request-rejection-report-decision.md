# Request rejection report decision (M3-084)

> **Current.** Not built yet: its "Next production slice" is M3-085.

Status: **decision** (M3-084, issue [#170](https://github.com/sano-suguru/muntin/issues/170)). Evidence: the pull request. Changes part of M3-058, M3-059 and M3-082's slice (below).

**Question and what settles it.** Muntin's 400s keep no cause: [M3-058](m3-058-dropped-error-report-decision.md) left them unreported, and [M3-059](m3-059-dropped-error-report-amendment.md) found that one can be a server-side fault. So an author finds why a request was refused only by reading Muntin's code: in #167 a misspelled member in a hand-written decoder answered every valid body 400 and logged nothing. Which 400s carry a report, through what Muntin-owned API, holding what of the request, and how does a conversion's server-side failure differ from bad input? Settled by every place `src/muntin` makes its 400, read in code; Mojo 1.1.0 probes of how a conversion could mark a failure as the server's; a scratch copy of production with the report passing `check.sh`, `test.sh` and `check_flare.sh` and a spike through `TestClient`; and a fresh-context review.

**Choice: each 400 Muntin makes before a handler carries a `Rejection`, read with `Response.rejection()`; the client gets the same 400.**
- `Rejection` (`Copyable`, `Writable` as `step name: message`): `step`, one of `PATH`, `QUERY`, `FROM_ROUTE_VALUE`, `UTF8`, `JSON` (not one JSON value), `FROM_BODY`, `FROM_BYTES`, `FROM_JSON`; `name`, the route value's placeholder; `message`.
- Muntin's own messages are fixed (`missing`, `not an integer`, the parser's, `JsonValue`'s) and hold no byte of the request. A `FROM_` message is the raised error's text: escaping and masking it are the application's, as for `Failure`, and a standard-library `Int(text)` in it quotes the client's text.
- A guarded route's deferred 400 carries it; a refusing guard answers first, with none. A carrier reports its body's step.
- None on 404, 405, 413, 415, 500, a backend's own 400 or an application's 400. `failure()` stays `None` on a 400, so M3-059's loggers are unchanged. One report slot: `Response` stays 80 bytes.
- `JsonValue[name]`'s error names the member. M3-083 keeps the two JSON steps for each body it adds and prefixes each derived failure with its member path (`notes[2].text: ...`).
- Nothing but its message tells a conversion's server-side fault from bad input, and it is answered 400: #167's misspelling reads as a missing member.

**Rejected.**
- New `Failure` sources: every M3-059 logger would start writing client-triggered lines unasked.
- Muntin's text only: #167's cause is the decoder's own error.
- Quoting the offending value: client bytes in logs, M3-058's reason.
- A typed conversion error (`comptime Fault: Deinitable = Error` in the four traits; compiles, existing conformers unchanged): no conversion in the repository fails for a server reason; four public traits, the carriers and M3-083 change. Deferred by the owner.
- An `App` hook, or printing by default: as M3-058.
- A second report list: `Response` 104 bytes.

**Revisit when** a server-side conversion fault must be told from bad input without reading its message, or answered other than 400 (the typed error above); an application needs the offending value, or a report on a backend's 400, 413 or 415.

**Next production slice (M3-085):** the prototype at `f01527c` (its `prototype-m3-084/README.md`).
- Code: as prototyped; exports `Rejection`.
- Tests: `tests/test_rejection.mojo` through `TestClient`: every step and fixed message, each name source (`Param` in a module of its own), a deferred and an in-slot 400 on guarded routes, carriers, `None` elsewhere, copies and `HEAD`, a middleware reading it, the size; a loopback 400 whose body and fields are unchanged; the whole-output fixture comparison (`Json` and `_from_parts` change).
- Docs: errors, middleware, route-values and bodies references, `docs/ARCHITECTURE.md`, `docs/SPEC.md`.
- Not in the slice: a typed conversion error, the offending value, a logger.
