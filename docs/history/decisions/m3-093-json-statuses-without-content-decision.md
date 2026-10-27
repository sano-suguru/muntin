# JSON statuses without content decision (M3-093)

> **Current.** Changes in part [M3-028](m3-028-json-response-status-decision.md) and [M3-091](m3-091-openapi-output-decision.md). Now described in [responses reference, "JSON results"](../../reference/responses.md#json-results).

Status: **decision**, built in its own pull request ([#206](https://github.com/sano-suguru/muntin/pull/206), the evidence) at the owner's choice: the fix is small but changes a decided behavior. Found reviewing M3-092 (#203).

**Question and what settles it.** M3-028 let `Json(value, status=)` write the value whatever the status, so a 1xx, 204, 205 or 304 carried a JSON body, which RFC 9110 forbids (sections 6.4.1, 15.3.6). Flare v0.12.0 sends that body as DATA over h2c, and a 205's over HTTP/1.1 too, where a kept-open connection reads it as the next response. Which of these does `Json` answer without a body, and what of a value that cannot be written? Settled by RFC 9110 and Flare's pinned framing, read from its source and observed over loopback.

**Choice.** For a 1xx, 204 or 205, `Json.to_response` answers that status with no body and no fields, and does not write the value: a value that cannot be written is not the fixed 500. `Content-Type` goes too, as it describes content these answers do not have. A 304 and every other status are unchanged: a 304 keeps its body because its `Content-Length` must be the length a 200 would carry (RFC 9110 section 8.6), and Flare frames it from the body over HTTP/1.1 while sending no content; an empty body would declare 0. Over h2c Flare still sends a 304's body as DATA, as before (ARCHITECTURE, "Current limits").

**Rejected.**
- A 304 without a body too: Flare then declares `Content-Length: 0` over HTTP/1.1, the error the adapter already cannot avoid for a `HEAD` 304 ([M3-026](m3-026-head-decision.md)); carrying the length beside an empty body needs a `Content-Length` the adapter trusts from the handler, which M3-026 rejected.
- Write the value, then drop the body: a pass, and a possible 500, for a value no one receives.
- Keep `Content-Type`: it describes content the answer does not have.
- The same rule on `Response` (M3-028's first revisit condition): a `Response` is sent as given ([raw reference](../../reference/raw.md)); that is a status policy for `Response`, a separate question.
- The fixed 500 for such a status, as a mistake: a 204 from a JSON route, such as a delete, is ordinary.

**Changed in M3-028 and M3-091.** M3-028's invariant "a chosen status reaches the response only through a successful `write_json`" holds for a status with a body. M3-091's "A `Json` 204 carries a body" no longer holds; the derived `2XX` still describes JSON content, so an application describes a `Json` 204 or 205 through an addition.

**Revisit when**: Muntin decides a status policy for `Response` (apply this set there); a backend can send a 304 with no body and no wrong `Content-Length` (a 304 can then lose its body too); or `Json` gains response header fields (a 304's `ETag`).

**Next production slice: this pull request.** `Json.to_response` and `_writes_no_body` (`src/muntin/json.mojo`); tests in `tests/test_json.mojo`, `GET /greet-as/{status}` in `adapters/flare/test_localhost_roundtrip.mojo` (raw HTTP/1.1 bytes of a 204, 205 and 304, h2c frames of a 204, 205 and 304), and the `Json` 204 in `tests/test_openapi.mojo` turned from a known gap into a described 204; the responses and OpenAPI references.
