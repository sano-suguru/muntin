# JSON media types decision (M3-094)

> **Current.** Not built yet (M3-095). Changes in part [M3-008](m3-008-json-codec-decision.md), [M3-028](m3-028-json-response-status-decision.md) and [M3-091](m3-091-openapi-output-decision.md).

Status: **decision** (M3-094, issue [#193](https://github.com/sano-suguru/muntin/issues/193)). Evidence: its pull request, [#207](https://github.com/sano-suguru/muntin/pull/207).

**Question and what settles it.** M3-008 answers 415 to a `Json[T]` body sent as a `+json` type or with no `Content-Type`. Which does a route accept, chosen where, spelled and shown how; does a result's media type (M3-028's third revisit condition) share it? Settled by the Fetch standard (which requests need a preflight), RFC 6839, 7396 and 9110, M3-089, M3-091, and production's compile-time `StaticString` parameters.

**Choice: each `Json` type names one media type, `Json[T, media=...]`, a body's and a result's each their own; a missing `Content-Type` stays 415.**

```mojo
def merge(id: Int, body: Json[UserPatch, media="application/merge-patch+json"]) raises -> Json[User]: ...
```

- `media: StaticString = "application/json"`, keyword-only. A body needs exactly one `Content-Type` of its media type, compared as M3-008 does; any other, `application/json` included, is 415. A result that writes its value carries exactly `Content-Type: <media>`, at any status the handler chose (a `Problem` 404 too); the fixed 500 and M3-093's bodiless answers carry none.
- `media` is `application/json` or `application/<token>+json`, lowercase, checked at compile time like `limit`; `openapi` writes it as the body's or the `2XX`'s content type. A browser preflights a cross-origin request with any such type (Fetch), so the send path M3-008 closed stays closed; other CSRF defence is the application's.
- `media` decides which requests reach the reader, not how it reads: a derived reader reads absent and `null` alike as `None`, so a merge patch (RFC 7396: absent keeps, `null` removes) needs a hand-written `FromJson` reader (`value.get`).
- No `Content-Type` is 415 everywhere: a browser sends that cross-origin without a preflight (a `Blob` with an empty type), where CSRF then depends on credentials and the application's checks; no client needing it is known. Middleware can add the field.

**Rejected.**
- Any `+json`, per route or by default: parseable is not understood (RFC 6839 keeps a type's semantics apart from generic JSON processing).
- `application/json` beside `media`, or a list: the type stops saying what the body means. `App`-wide: unseen in the signature and `openapi`.
- Accepting a missing `Content-Type`, per route or `App`-wide: widens what a browser can send for no known client; adding it later is additive.
- `Json(v, media=)` on results only: unseen by requests and `openapi`, checked at run time. Ending the edit that labels the fixed 500 is a gain, not the reason.

M3-089's condition "a second such parameter" fires: `media` means something on a result too, so repeating it says what is sent.

**Revisit when** a named client cannot send `Content-Type` and that route's CSRF defence is shown; a route needs two media types of one meaning; `Accept` negotiation or dispatch by `Content-Type` is decided; `Json` gains response header fields.

**Next production slice (M3-095): `Json[T, media=...]`.**
- Code: `json.mojo` (parameter, check, request rule, `to_response`), `app.mojo`'s JSON step, `openapi`.
- Tests (`test_json.mojo`, `test_openapi.mojo`): the default unchanged; `media=` accepts its type with parameters, any case, refuses `application/json`, another `+json`, none and two, on every shape; body and result of different media on one route; results carry it at 200 and a chosen 404 and 500, not the fixed 500 or a 204. Must-not-build fixtures (`text/plain`, upper case, empty, no `+json`), a revisit index row; a `media=` route in loopback `json_app()`.
- Verification: section 3, with the whole-output comparison.
- Docs: bodies (the merge-patch note), responses (no more media-type edit), OpenAPI, ARCHITECTURE, SPEC.
