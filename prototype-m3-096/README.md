# M3-096 prototype (evidence for its pull request, not for merging)

Base: `fb04dda` (main when the pull request was opened). The commit of
this prototype is the one the decision record's "Next production slice"
names; the pull request's next commit removes it again, so `src/muntin` is
unchanged when the decision merges.

What changed against the base:

- `src/muntin/json.mojo`: `_bare_json[X]()` (a `JsonFields` struct, or a
  `List` of one) and `_is_json[X]()` (that, or a `Json[T]`);
  `Json.to_response`'s body moves to `_json_response[T](value, status)`,
  which `_respond` calls for a bare result: Mojo 1.1.0 cannot call the
  `where`-gated `Json[R].to_response` from inside `comptime if
  _bare_json[R]()` ("lacking evidence to prove correctness").
- `src/muntin/app.mojo`: the 40 overloads' result clause gains `or
  conforms_to(R, JsonFields) or conforms_to(R, Iterable)` (a `where` clause
  cannot call `_bare_json`); `_respond` answers a bare result with
  `_json_response(result^, 200)`; `_slot` takes a bare body through
  `Json[A]`'s steps (415, 413 over `Json[A].max_bytes`, `_convert_body`,
  then `take()`, so no rebind); `_route`'s `json` flag and `_guarded_at`
  read `_is_json`; `Group.__init__` refuses a context type that is a bare
  JSON type, with its own message naming the migration (wrap it in a
  struct of the application's own), before the existing `_OTHER` assert.
- `src/muntin/_registration_rules.mojo`: `_kind` gives a bare JSON type
  `_BODY`, or `_AMBIGUOUS_JSON` when it also conforms to `RouteValues`,
  `FromRouteValue`, `FromBody` or `FromBytes`; `_rule` refuses that
  (`_JSON_AMBIGUOUS`), a result that is a `JsonFields` struct and a
  `ToResponse` (`_RESULT_JSON_AMBIGUOUS`), and an `Iterable` result that is
  neither a bare JSON type nor a `ToResponse` (`_RESULT_KIND`: `List[Int]`,
  `Optional[T]`, `Dict`), before any `R == StaticString` test, each with a
  message; `_json_ok` and `_check_json` read `_refusal[X, reading]()` for a
  bare body, and for a bare result that is not a `ToResponse`, naming the
  innermost field as for `Json[T]`. The body-type messages add "or be a
  JsonFields struct or a List of one".
- `src/muntin/_openapi.mojo`: a bare body is a required `application/json`
  body, a bare result a `200` `application/json` response, each with the
  schema `Json[T]` gives.
- `tests/test_registration.mojo`: the two helpers that copy the whole
  result clause copy the new one; with the old clause they no longer
  build (`lacking evidence to prove correctness`).
- `tests/bare_json_fail/` (built by `check.sh`): fourteen must-not-build
  fixtures. Against the base's `src`: `body_also_from_body`,
  `body_also_from_bytes`, `body_also_record`, `result_also_to_response`
  and `group_context` (a guard returning a `JsonFields` `User` as the
  Group's context) build there; `list_of_string_body` fails there with the same text, so it
  is a regression pin; the others fail there with other text (candidate
  notes, a route-value message, or the `FromBody` body message).
- `tests/test_spike_bare_json.mojo`: the spike (5 tests, built with
  `-D MUNTIN_OPENAPI`).

- `tests/json_api_fail/derived_alone_is_not_a_body.mojo`: removed; the
  bare `JsonFields` body it refused builds now.

No check is expected to fail.

Reproduce from this commit's root (Linux, pixi): `./scripts/check.sh`,
`./scripts/test.sh`, `SANITIZE=address ./scripts/test.sh
tests/test_spike_bare_json.mojo`, `./scripts/check_flare.sh`.
