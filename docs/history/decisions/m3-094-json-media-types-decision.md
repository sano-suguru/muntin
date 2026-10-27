# JSON media types decision (M3-094)

> **Current.** Not built yet (M3-095). Changes in part [M3-008](m3-008-json-codec-decision.md), [M3-028](m3-028-json-response-status-decision.md) and [M3-091](m3-091-openapi-output-decision.md).

Status: **decision** (M3-094, issue [#193](https://github.com/sano-suguru/muntin/issues/193)). Evidence: [#207](https://github.com/sano-suguru/muntin/pull/207).

**Question and what settles it.** M3-008 answers 415 to a `Json[T]` body sent as a `+json` type or with no `Content-Type`. Which does a route accept, chosen where, spelled and shown how; does a result's media type (M3-028's third revisit condition) share it? Settled by Fetch's preflight rule, RFCs 6838, 6839, 7396, 9110, JSON:API 1.1, M3-089, M3-091 and Mojo probes.

**Choice: each `Json` type names one media type, `Json[T, media=M]`, a body's and a result's each their own; a missing `Content-Type` stays 415.**

```mojo
struct MergePatch(JsonMedia):
    comptime name = "application/merge-patch+json"

def merge(id: Int, body: Json[UserPatch, media=MergePatch]) raises -> Json[User]: ...
```

- `media`, keyword-only, is a `JsonMedia` type, `ApplicationJson` by default. A body needs exactly one `Content-Type` naming it (compared as M3-008 does); any other type is 415, `application/json` included. On a declared `+json` type any `;` parameter is 415, as one can change the meaning (JSON:API's `ext`), while `application/json` still ignores them. A result that writes its value (a 304 too) carries exactly `Content-Type: <name>` at any status the handler chose; the fixed 500 and M3-093's bodiless answers carry none.
- `name` is `application/json`, or `application/` and a lowercase RFC 6838 restricted-name subtype ending in `+json`, checked at compile time where `Json` is read, written or described. `openapi` writes it as the content type. A browser preflights a cross-origin request of any such type, so M3-008's closed send path stays closed; other CSRF defence is the application's.
- `media` gates the reader only: a derived reader reads absent and `null` alike, so a merge patch (RFC 7396) needs a hand-written `FromJson` reader.
- No `Content-Type` is 415 everywhere: a browser sends it cross-origin unpreflighted (an untyped `Blob`), where CSRF then depends on credentials and the application's checks; no client needs it yet. Middleware can add it.

**Rejected.**
- `media: StaticString`: crashes `discover_tests` in any module naming `Json`, even at its default (`tests/named_values_api_fail/discover_tests_crash.mojo`).
- Any `+json`, per route or by default: parseable is not understood (RFC 6839). Ignoring a declared type's parameters: the same, and tightening later breaks clients.
- `application/json` beside `media`, or a list: the type stops saying what the body means.
- Accepting a missing `Content-Type`: widens what a browser can send, for no known client; it can be added later.
- `App`-wide, or `Json(v, media=)` on results: unseen in the signature or by `openapi`.

M3-089's second-parameter condition fires; `media` also means something on a result.

**Revisit when** a client needs a parameter on a declared type (`JsonMedia` then names those accepted); a named client cannot send `Content-Type` and that route's CSRF defence is shown; a route needs two media types of one meaning; `discover_tests_crash.mojo` builds (weigh a string); `Accept` negotiation or `Json` response fields are decided.

**Next production slice (M3-095).**
- Code: `json.mojo` (`JsonMedia`, `ApplicationJson`, exported; the check; `_JsonBody`'s media; `to_response`); `_Route.json` becomes the media name, read by `App.handle`'s rule; `WithHeaders` forwards it; `openapi`. A raw `from_body` still checks no `Content-Type`.
- Tests (`test_json.mojo`, `test_openapi.mojo`): the default unchanged; `media=` takes its type in any case, refuses it with a parameter, `application/json`, other `+json`, none and two, on every shape; body and result of different media; results carry it at 200, 304 and a chosen 404, not the fixed 500 or a 204; the media-type edit's example and test become `media=`; must-not-build fixtures for bad names (a 128-byte subtype; 127 builds), a revisit index row; a loopback `media=` route.
- Verification: section 3, with the whole-output comparison.
- Docs: bodies, responses, OpenAPI, ARCHITECTURE, SPEC.
