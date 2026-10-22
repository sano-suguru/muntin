# M3-084 prototype (evidence for its pull request, not for merging)

Base: `6e8e800` (main when the pull request was opened). The commit of this
prototype is the one the decision record's "Next production slice" names;
the pull request's next commit removes it again, so `src/muntin` is
unchanged when the decision merges.

What changed against the base:

- `src/muntin/http.mojo`: `Rejection`, with its step constants;
  `Response.rejection()`; `Response._failure: List[Failure]` became
  `_report: List[_Report]`, one element holding either a `Failure` or a
  `Rejection` and, until `App.handle` names it, the rejected route value's
  position; `_rejected_by`, Muntin's 400 with its report.
- `src/muntin/app.mojo`: `_Reject` carries the step, the route value's
  position and the message; `_slot` fills them for an `Int` or
  `Optional[Int]` parse (`PATH`, turned into `QUERY` for a query value),
  `from_route_value` and every body; `_dispatch` gathers and decodes the
  route values in `_route_values`, which raises the same, and names a
  rejected value from the route (`_value_name`, `_name_rejected_value`); a
  guarded route's deferred 400 passes its step, name and message to
  `_run_guard` ahead of the header fields; `_parse_int` no longer lets
  `Int`'s own message, which quotes the text, through; `_decode_value`'s
  and `_query_spans`' messages are the fixed vocabulary.
- `src/muntin/body.mojo`: `_BodyFault`, a body conversion's step and
  message; `_NOT_UTF8`.
- `src/muntin/headers_body.mojo`: `_convert_body`, the bare body
  conversion (`FROM_BYTES`, `UTF8`, `FROM_BODY`, or `Json`'s two steps),
  which `_slot` and `WithHeaders._from_parts` share; `_from_parts` raises
  `_BodyFault`.
- `src/muntin/json.mojo`: `_JsonText`, `Json[T]._from_text` (`JSON` for
  the parse, `FROM_JSON` for `from_json`); `JsonValue[name]`'s missing
  member error names the member.
- `src/muntin/__init__.mojo`: exports `Rejection`.
- `tests/test_spike_rejection.mojo`: the spike (9 tests).

Reproduce from this commit's root (Linux, pixi): `./scripts/check.sh`,
`./scripts/test.sh` (the spike included), `./scripts/check_flare.sh`.
