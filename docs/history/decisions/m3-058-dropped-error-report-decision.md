# Dropped error report decision (M3-058)

> **Current.** Now described in [errors reference, "Reports of dropped errors"](../../reference/errors.md#reports-of-dropped-errors), [middleware reference, "Logging dropped errors"](../../reference/middleware.md#logging-dropped-errors) and [ARCHITECTURE, "Request handling"](../../ARCHITECTURE.md#request-handling).
> Changed in part since:
> - [M3-059](m3-059-dropped-error-report-amendment.md): Response._failure became a List[Failure]; two premises (what the outermost logger sees, what a 400 means) corrected.
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

Status: **decision** (M3-058, pull request #107, which holds the probes, the scratch production run and the reviews; `src/muntin` unchanged). It answers the revisit condition on an observability or logging hook in [M2-010](m2-010-application-error-decision.md) and [M2-012](m2-012-error-response-decision.md), not M2-012's on a fallible conversion. It adds to `Response` and changes no existing answer or member, so it amends M2 rather than reopening it.

**Question and what settles it.** Muntin answers some failures with the fixed 500 and drops the error unread, so its text never reaches the client ([M2-011](m2-011-raising-handlers-in-production.md)); an application then cannot learn what failed or on which request. Which dropped errors should an application be able to observe, through what Muntin-owned API, carrying what? Settled by every place Muntin makes the fixed 500, read in code; what Mojo 1.1.0 can produce from a caught value of a generic error type, probed; and the choice applied to a scratch copy of production with the three scripts run on it.

**Facts** (Mojo 1.1.0; read in code unless marked measured):
- `src/muntin` makes the fixed 500 in six places: a handler error whose declared type does not conform to `ToErrorResponse` (`_handler_error`); a raise out of a middleware (`_run`); a `Json[T]` whose `write_json` raises (`Json.to_response`, also when a handler calls it); a slot rebuild failure (`_Reject(500)`, only the M3-002 `_fields` gap; `_slot` discards the caught error); a raise out of a route's `invoke`, which no adapter makes; and a failed `Allow` write. The first three happen on ordinary paths. After `App.handle`, the Flare adapter makes its own 500 for an outgoing field that fails its re-check (only the `_fields` gap).
- A converted error is not dropped: the application's `to_error_response` runs on it. Muntin's 400s drop the error behind each request-side failure (a route value's decoding or conversion, UTF-8, `from_body`, `from_bytes`, a carrier's conversion).
- Under `comptime if conforms_to(E, Writable)`, `String(e)` of a caught `E` compiles and gives an `Error`'s message or an application type's own text; `reflect[E].name()` gives any other type's module-qualified name (measured). `Error.get_stack_trace()` returned `None`, even with `MOJO_ENABLE_STACK_TRACE_ON_ERROR=1` in a `-g` build (measured).
- Middleware sees every response `App.handle` makes and the request it answers ([M3-034](m3-034-middleware-decision.md)), not a backend's own answers or a streamed response's pulls ([M3-056](m3-056-streaming-responses-and-cancellation-decision.md), not shipped); its configuration is compile-time only.
- `Response` is 56 bytes, and 112 with an inline `Optional` of a two-`String` report (measured, `size_of`).

**Choice: each fixed 500 `src/muntin` makes carries a report of what it dropped, which middleware reads; Muntin prints nothing.**
- A public, Muntin-owned `Failure` (`Copyable`, `Writable`, written `source: message`): `source`, the step that dropped it, one of the constants `Failure.HANDLER`, `Failure.MIDDLEWARE`, `Failure.RESPONSE` (a result conversion) and `Failure.MUNTIN` (Muntin's own internal failures); and `message`, the error's text when its type is `Writable` (`Error` included), else `<`, its type's name and `>`. Its initializer takes only `_`-prefixed keyword arguments.
- `Response.failure() -> Optional[Failure]` returns a copy of the report. The six sites set it; a public initializer never does, so it is `None` on a response the application builds, on Muntin's 400, 404, 405, 413 and 415, and on a converted error. It travels with the response: copies, `HEAD` and edits of the status, body or fields keep it (a `Json[T]` converted and given another status, a 500 turned into a 503); only a new response drops it.
- No backend sends it: a backend converts the status, fields and body only, so the client receives what it does today.
- Observing is middleware: an application that wants every report registers its logging middleware first, keeps the request's method, path and request ID field before `next`, and reads the report after it. A raise out of that outermost middleware, and the adapter's own 500, carry a report nobody reads or none.
- The text reaches application code, never the client unless the application writes it out. Request IDs, timing, metrics and tracing stay application middleware.

**Rejected.**
- An `App` hook (`app.on_error(f)`, `f(request, failure)`): a second observation concept beside middleware. Called by `App.handle` it adds only the outermost middleware's raise; called by a backend too, it also reaches the adapter's 500 and a future stream's raise, but widens the seam (A4) for a failure no ordinary path reaches and a feature not shipped.
- Printing dropped errors to standard error by default: Muntin would choose the sink and format, and an error's secrets would go where the application did not choose.
- The typed error value instead of text: a second erased box in `Response`, of a type middleware cannot name.
- Reports on the 400s: client-controlled text in the server's log lines, for a status the client fixes; revisit below.
- Reports on converted errors: the application's own conversion already runs on the value.
- The report behind an `ArcPointer` (`Response` 72 bytes, measured): its value is mutable through any copy, why `State` does not use one; the size is not shown to matter.

**Revisit when:**
- streamed responses ship (M3-057): a stream's raise happens after middleware, so decide whether a backend reports it, and through what;
- an application needs the reason for a 400, or a failure the outermost middleware cannot see;
- Mojo's `Error` carries a stack trace or source location a report could hold;
- runtime-configured middleware or a `State` bound to middleware ships (M3-034): a logger configured at start-up becomes expressible;
- the comparison with Flare alone measures `Response`'s size as a cost.

**Next production slice (M3-059):**
- `src/muntin`: `Failure` in `http.mojo`, exported from `muntin`; `Response._failure: Optional[Failure]`, `None` from every public initializer, and `Response.failure()`. Sources and messages: `_handler_error`, `Failure.HANDLER` and the error's text or type name; `_run`, `Failure.MIDDLEWARE` and the `Error`'s message; `Json.to_response`, `Failure.RESPONSE` and the `Error`'s message; `_rejected` for `_Reject(500)`, `Failure.MUNTIN` and fixed text naming the rebuild; `invoke`'s raise and the `Allow` write, `Failure.MUNTIN` and the caught `Error`'s message. `_internal_error()` stays, without a report, since spikes under `tests/` import it. No change to `_handler_storage.mojo`, `check_unsafe.sh`, the adapter, `TestClient` or any registration overload.
- Tests, in a new `tests/test_failure.mojo` through `TestClient`: each reachable source with its text (an `Error`, a `Writable` type, another type's name, a middleware raise read by the middleware outside it, a `Json[T]` serialization failure, a rebuild failure through the `_fields` gap); `None` on a converted error, an application's own 500, 400, 404, 405, 413 and 415; the body unchanged; `HEAD`, a copy, a converted `Json[T]` given another status and a middleware that changes the status keep the report; a middleware that builds a new response drops it; an outermost logging middleware reads method, path, a request ID field and the report together.
- Loopback: the existing `find_order` case in `adapters/flare/test_localhost_roundtrip.mojo`, whose error text is a secret, gains a check that neither the body nor any field carries it.
- Measure, reported in the pull request: a plain-text `GET` with and without middleware against the base, since every `Response` grows.
- Docs: `docs/DX.md` section 6 (the report and what carries one; that `message` may hold secrets, control characters and client-supplied values, so escaping and masking it in a log are the application's) and section 7 (a logging middleware registered first; a client's request ID field is not trusted); `docs/ARCHITECTURE.md` request handling (the 500 rows) and "Other current limits"; `docs/SPEC.md` (the capability row; the candidate keeps what is not in the slice).
- Not in the slice: a default logger, request IDs, timing, metrics, tracing, reports on the 400s, on the adapter's 500 or on a stream's raise, a stack trace.
