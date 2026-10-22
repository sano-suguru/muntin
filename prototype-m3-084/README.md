# M3-084 prototype (evidence for its pull request, not for merging)

Base: `6e8e800` (main when the pull request was opened). This revision
replaces `f01527c`, whose repeated-key search rescanned the query once per
key. The commit of this prototype is the one the decision record's "Next production slice" names;
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
  messages are the fixed vocabulary. `_query_spans_at` gives a repeated
  key's position from its one pass (`_query_spans` keeps its signature
  for `tests/test_query_spans.mojo`), so finding the key scans the query no
  more than the base does.
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
- `tests/test_spike_rejection.mojo`: the spike (9 tests), with a repeated
  key on a route of nine query keys.

Reproduce from this commit's root (Linux, pixi): `./scripts/check.sh`,
`./scripts/test.sh` (the spike included), `./scripts/check_flare.sh`.
