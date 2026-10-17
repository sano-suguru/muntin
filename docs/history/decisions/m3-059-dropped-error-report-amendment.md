# Dropped error report amendment (M3-059)

> **Current.** Now described in [errors reference, "Reports of dropped errors"](../../reference/errors.md#reports-of-dropped-errors), [middleware reference, "Logging dropped errors"](../../reference/middleware.md#logging-dropped-errors) and [ARCHITECTURE, "Request handling"](../../ARCHITECTURE.md#request-handling).
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

Status: **amendment** to "Dropped error report decision (M3-058)", made in its slice M3-059 (pull request #116, which holds the measurements and the review that prompted it). M3-058's choice stands: each fixed 500 `src/muntin` makes carries a `Failure` that middleware reads, and no public API changes.

**Delta to the slice.**
- `Response._failure` is a `List[Failure]`, empty or holding the one report `_failed` appends to the response it has just built, instead of an `Optional[Failure]`: `Response` is 80 bytes, not 112.
- `docs/DX.md` section 7's logging middleware quotes the method, path, request ID and message, writing each byte outside printable ASCII as `\xNN`. It passed the method and path through raw, and `repr` leaves C1 controls and other non-ASCII characters as they are, so a client could put an escape sequence in the log through the path.
- Two premises of M3-058 are corrected in the docs; its choice is not reopened. A logging middleware registered first reads the report on the response it receives, not every dropped error: a middleware inside it that answers a 500 with a new response drops the report, and one that raises after a handler failure replaces it with its own. And a 400 is not only a status the client fixes: an application conversion that fails for a server-side reason is the same unreported 400 as bad input. Tests pin both.

**Why.** The review measured the 112-byte `Response` as a cost against `main` on the success path with middleware; M3-058's revisit condition named a comparison with Flare alone, but guards against the same cost, and the `List` recovers most of it. M3-058 rejected an `ArcPointer` because its value is mutable through any copy; a `List` copies its element with the response, so no two responses share a report.

**Boundary.** `Failure`, `Response.failure()`, the six sites, the sources and messages and what keeps a report are unchanged. The invariant: `_failure` holds at most one report, and only `_failed` adds it.

**Revisit when**: M3-058's "an application needs the reason for a 400, or a failure the outermost middleware cannot see" now also covers a failure a middleware inside the logger drops or replaces, and a 400 an application conversion makes for a server-side reason, which needs a way for the conversion to say which it is.
