# JSON response status decision (M3-028)

> **Current.** Changed in part by [M3-093](m3-093-json-statuses-without-content-decision.md): a status that never carries content (1xx, 204, 205, 304) has no body or fields, and the value is not written. Now described in [responses reference, "JSON results"](../../reference/responses.md#json-results) and [ARCHITECTURE, "Revisit index"](../../ARCHITECTURE.md#revisit-index).
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

Status: **decision** (M3-028, PR #64; `src/muntin`, `adapters/` and `tests/` are unchanged in it). It decides how a handler answers a `Json[T]` result with a status other than 200. Today `Json[T].to_response()` answers 200, and another status is an edit of the converted `Response` (DX section 5).

**Why this candidate.** The registration and method work SPEC tracked is shipped through M3-027, and AGENT_PROGRESS names no next item. Of SPEC's remaining candidates, `Json(value, status=)` is the smallest user-visible capability: `201 Created` for a `POST` that creates a resource and `202 Accepted` are ordinary JSON API answers, and today each needs a handler declared `-> Response`. M3-008 left it out of its slice and M3-022 deferred it because an application `ToResponse` type answers with any status. What is open is public: the spelling, where the status lives on a type that is also a request body, what a serialization failure answers when a status was chosen, and whether Muntin checks the value.

**Question.** How does a handler choose the status of a `Json[T]` result? Specifically: the spelling, and whether `Json(value)` keeps its meaning and every existing call site; where the chosen status is held until the conversion, given that `Json[T]` is also a request body built by `from_body`; whether the chosen status changes the answer to a serialization failure (the fixed 500 without `Content-Type`); whether Muntin validates the value; and which statements of DX, SPEC and the M2 contract, and which diagnostics, change.

**What settles it:**
- what the documented workaround (DX section 5: `var r = Json(v).to_response(); r.status = 201`) answers when `write_json` fails, measured through `TestClient`;
- whether `Json(value)`, `Json[T](value)`, `Json(v^)` with a move-only `T`, `take(deinit self)` and `from_body` still compile and behave with the status held on `Json`, on a scratch copy of `src/muntin/json.mojo`;
- which existing fixture or test prints `Json`'s initializer or fields, found in `tests/`, and so whether the base-wide diagnostic comparison (`docs/DEVELOPMENT.md` section 3) applies to the slice;
- the existing status policy: what `Response`, `Response.text` and the backend do with an arbitrary `Int` status, read from `src/muntin/http.mojo` and `docs/ARCHITECTURE.md`, so the decision adds no validation of its own unless one exists;
- what the backend does with the chosen status, `HEAD` included (M3-026's rule reads the response's status), read from the adapter.

**Selected: `Json(value, status=201)`, a keyword-only `status: Int = 200` on `Json`'s initializer, held on the `Json` value and applied by `to_response` to the successful answer only.** A serialization failure stays the fixed 500, whatever status was chosen. Muntin does not validate the value. No overload, trait, public type or field is added.

```mojo
def create_user(var body: Json[NewUser]) raises -> Json[User]:
    var user = users.add(body^.take())
    return Json(user^, status=201)    # 201, the body and Content-Type of Json(user^)
```

- **Spelling.** `status` is keyword-only, after the value, with the default 200. `Json(value)`, `Json[T](value)` and `Json(v^)` keep their meaning, so every existing call site compiles and answers as before. Keyword-only because `Response(status, body)` and `Response.text(body, status)` already order the two differently: `Json(v, 201)` would be a third order to remember, and making the keyword positional later is additive.
- **Where the status lives.** A private field of `Json` (`_status`), set by the initializer and read once by `to_response`. The `Response` that `to_response` returns carries it from then on; nothing reads the field after the conversion, so there is one status at a time. `Json[T]` is also a request body. Mojo 1.1.0 has no conditional fields, so a body built by `from_body` holds the field too, with the default 200, and nothing on the request path reads it: the 415, 413 and 400 steps, `from_body`, `value` and `take` are unchanged. The field is private so that a body exposes no status to the handler; a public field (`j.status = 202`) would be additive later.
- **Serialization failure.** `to_response` writes the value first and builds the answer with the chosen status only when `write_json` succeeds. A raising or unbalanced `write_json`, or a non-finite number, answers the fixed 500 without `Content-Type`, as `Json(value)` does. This is the semantic that D0 cannot express: measured, the workaround answers `201 Internal Server Error`.
- **Validation.** None. `Response(status, body)` and `Response.text(body, status=)` accept any `Int`, and the Flare adapter copies it to the wire (`to_flare_response`); no record decides a status policy, and this one does not invent one. A status that never carries content (1xx, 204, 205, 304) with a JSON body is what `Response(204, "x")` is today.
- **Backends.** Unchanged. The status is on the `Response` that `App.handle` returns, so every backend sends it as it sends any handler status, and M3-026's `HEAD` rule reads it there (no `Content-Length` for 1xx, 204, 205 or 304).

**Measured premises.**
- D0, through `TestClient` on `main`: a handler following DX section 5's override (`var r = Json(Measurement(nan)).to_response(); r.status = 201; return r^`) answers `201` with body `Internal Server Error` and no `Content-Type`; `Json(Measurement(nan))` returned directly answers `500`.
- On a scratch copy of `src/muntin/json.mojo` with the selected change (not retained), through `TestClient` and `App.handle`: `Json(v)` and `Json[T](v)` answer 200 with `Content-Type: application/json`; `Json(v, status=201)` and `status=418` answer that status with the same body and field; `Json(nan, status=201)` answers the fixed 500 without the field; a `post` handler `def(var body: Json[Token])` with a move-only `Token` returns `Json(body^.take(), status=201)` and answers 201 with the echoed body, and the stateful `def(State[Int], var body: Json[Token])` with `status=202` answers 202; `HEAD` on a `get` route returning `status=201` answers 201 with the body in memory. `Json(v, 201)` does not compile (`no matching function in initialization`).
- That rejected call's candidate note prints `Json.__init__`'s signature (`def __init__(out self, var value: Self.T, *, status: Int = 200)`). No checked expected text names it (`grep` of `tests/` for the fixtures that mention `Json`), but a fixture's full output can, so the slice runs the base-wide comparison.

**Candidates.**

| Candidate | Verdict |
|---|---|
| D0: keep the override (convert, then set `r.status`) | rejected: measured, it turns the fixed 500 into a success status with an error body, and each such handler is declared `-> Response`. It stays the way to change the media type |
| A. keyword-only `status: Int = 200` on the initializer, private field, applied on success | **chosen** |
| A′. A with `status` positional | rejected: a third argument order beside `Response` and `Response.text`; additive later |
| B. a public `status` field, set after construction | not now: a request body would expose a field that means nothing on the request path; additive beside A |
| C. a compile-time parameter, `Json[T, 201]` | rejected: the status becomes part of the result type, so `-> Json[User]` cannot return 201 on one path and 200 on another, and every existing `Json[T]` signature would gain a parameter |
| D. a separate response type (`JsonResponse[T]`) or a generic status wrapper over any `ToResponse` | rejected: a second JSON result type, or a layer every result type passes through, for a value `Response` already carries; an application `ToResponse` type and `Response.text` already choose their own status, so a status on `Json` is the uniform shape |

**M2 contract: not reopened.** `Json` is not in it (M3-009). By kind: the accepted set grows (calls with `status=` compile; no call that compiled is rejected or changes meaning); the overload set is unchanged; diagnostics: any candidate note that prints `Json.__init__` prints the new signature (the slice measures which); the runtime answer of every existing route is unchanged.

**Invariants:**
- `Json(value)` answers exactly what it answered before: 200, the written body, exactly `Content-Type: application/json`.
- A chosen status reaches the response only through a successful `write_json`; a serialization failure is the fixed 500 without `Content-Type`.
- Nothing on the request path reads the status.

**Cost.** One `Int` on every `Json` value, request bodies included. The status cannot be read back from a `Json` (it is private). A wrong value (`status=2001`) is not caught by Muntin.

**Revisit when:**
- Muntin decides a status policy for `Response` (a range, or a rule for a body on 1xx, 204, 205 or 304): apply it to `Json`'s status in the same place;
- applications need to read or change a `Json` value's status after construction: revisit whether candidate B is worth a public field on a request body;
- `+json` media types or response header fields on `Json` are decided: weigh whether they share this initializer.

**Next production slice (M3-029): `Json(value, status=)`.**
- Code: `src/muntin/json.mojo` only. `Json` gains a private `var _status: Int`; `__init__(out self, var value: Self.T, *, status: Int = 200)`; `to_response` builds `Response(self._status, ...)` on the success branch, its 500 branch unchanged; `from_body`, `take` and `value` unchanged. The module and `Json` docstrings say the status is the chosen one, 200 by default, and a serialization failure is still the fixed 500.
- Tests, in `tests/test_json.mojo` through `TestClient` (results) and `App.handle` (JSON bodies): `Json(value)` still 200 with exactly one `Content-Type: application/json`; `status=201` gives the same body and field as the 200 answer; a second, non-2xx status (418) passes through; `status=201` with a serialization failure is the fixed 500 without the field; a JSON-body `post` handler returning `Json(body^.take(), status=201)` and its stateful form (`status=202`); `HEAD` through a `get` route returning `status=201` answers 201 in memory. `tests/test_json_dx.mojo` follows DX section 5's new example. The existing override test stays (it is how the media type changes). A must-not-build fixture, `tests/json_api_fail/positional_status.mojo`, pins that `status` is keyword-only (`Json(value, 201)`; its expected text is the initializer's signature, which the compiler quotes under the candidate note), with a revisit index row in `docs/ARCHITECTURE.md`.
- Loopback: `adapters/flare/test_localhost_roundtrip.mojo`'s `json_app()` gains a `status=201` route, compared with `App.handle` (status, body, `Content-Type`) as its entries are.
- Verification: `docs/DEVELOPMENT.md` section 3, including the base-wide diagnostic comparison (the initializer's signature can appear in candidate notes), the new fixture built against the base's `src`, and a local `check_flare.sh` run.
- Docs: `docs/DX.md` section 5 (the status with `Json(value, status=)`, the default, the 500 rule; the override kept for the media type) and section 4 where it states the JSON result is 200; `docs/ARCHITECTURE.md` (the `Json` paragraph; `Json(value, status=)` leaves "Other current limits"; the revisit index row); `docs/SPEC.md` (the M3 table gains the capability as shipped; "JSON follow-ups" without it); `AGENT_PROGRESS.md`.
- Not in the slice: a status policy or validation, a public status field, response header fields or another media type on `Json`, `+json`, top-level list results, any change to `Response`, the adapter or `App.handle`.
