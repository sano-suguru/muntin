# JSON statuses without content decision (M3-093)

> **Current.** Changes in part [M3-028](m3-028-json-response-status-decision.md) and [M3-091](m3-091-openapi-output-decision.md). Now described in [responses reference, "JSON results"](../../reference/responses.md#json-results).

Status: **decision**, built in its own pull request ([#206](https://github.com/sano-suguru/muntin/pull/206), the evidence) at the owner's choice: the fix is small but changes a decided behavior. Found reviewing M3-092 (#203).

**Question and what settles it.** M3-028 let `Json(value, status=)` write the value whatever the status, so a 204, 205 or 304 carried a JSON body and `Content-Type`. RFC 9110 gives these statuses no content (sections 6.4.1, 15.3.6, 15.4.5); on a connection kept open, a client or proxy reads such bytes as the start of the next response, and over HTTP/1.1 Flare frames a 304 with the body's length. What does such an answer carry, for which statuses, and what of a value that cannot be written? Settled by RFC 9110 and the set Muntin uses for `HEAD` ([M3-026](m3-026-head-decision.md)).

**Choice.** For a status that never carries content (1xx, 204, 205, 304: M3-026's set), `Json.to_response` answers that status with no body and no fields, and does not write the value: a value that cannot be written is not the fixed 500. Every other status is unchanged. `Content-Type` goes too: it describes content a 204 does not have, and it is not among the fields RFC 9110 has a 304 send.

**Rejected.**
- 204, 205 and 304 only: a 1xx carries no content either, and a second set beside M3-026's would drift from it.
- Write the value, then drop the body (keeping M3-028's rule that a chosen status needs a successful write): a pass, and a possible 500, for a value no one receives.
- Keep `Content-Type`: it describes content the answer does not have.
- The same rule on `Response` (M3-028's first revisit condition): a `Response` is sent as given, the raw way to choose every byte ([raw reference](../../reference/raw.md)); that is a status policy for `Response`, a separate question.
- The fixed 500 for such a status, as a mistake: a 204 from a JSON route, such as a delete, is ordinary.

**Changed in M3-028 and M3-091.** M3-028's invariant "a chosen status reaches the response only through a successful `write_json`" holds for a status that carries content. M3-091's "A `Json` 204 carries a body" no longer holds; the derived `2XX` still describes JSON content, so an application describes a `Json` 204 or 205 through an addition.

**Revisit when**: Muntin decides a status policy for `Response` (apply this set there); `Json` gains response header fields (a 304's `ETag` or `Cache-Control`); or the OpenAPI output learns which statuses a `Json` route answers.

**Next production slice: this pull request.** `Json.to_response` and `_never_carries_content` (`src/muntin/json.mojo`); tests in `tests/test_json.mojo` (each status of the set and its neighbours, a value that cannot be written), `POST /greet-none/{status}` in `adapters/flare/test_localhost_roundtrip.mojo` (a 204 and a 304 on the wire), and the `Json` 204 in `tests/test_openapi.mojo` turned from a known gap into a described 204 (`scripts/validate_openapi.py`); the responses and OpenAPI references.
