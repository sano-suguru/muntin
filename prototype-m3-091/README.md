# M3-091 prototype (evidence for its pull request, not for merging)

Base: `ec43bf8` (main when the pull request was opened). The commit of
this prototype is the one the decision record's "Next production slice"
names; the pull request's next commit removes it again, so `src/muntin` is
unchanged when the decision merges.

What changed against the base:

- `src/muntin/_openapi.mojo` (new): `_operation[A, B, C, R]`, the OpenAPI
  3.1 operation of a route from its slot and result types: parameters,
  request body, responses.
- `src/muntin/json.mojo`: `_write_schema[F, reading]`, the JSON Schema of
  what the derived codec reads or writes, by `_kind_ok`'s rules (a
  hand-written direction is `{}`); `_JsonBody._schema`, which `Json`
  implements.
- `src/muntin/headers_body.mojo`: `_HeaderCarrier._carries_bytes`;
  `WithHeaders._schema` for a carried `Json[T]`.
- `src/muntin/app.mojo`: `_route` takes the result type `R` (every call
  site passes it, `_add_guarded_route` too) and stores `_operation[A, B,
  C, R]` and the literal in the `_Route` (`describe`, `literal`; a `_Route`
  built without types, as two tests do, gets `_no_operation`);
  `_App.openapi(*, title, version, document="", operations={}) raises ->
  String`, an `App`'s alone (`comptime assert`), and `_document`, which
  raises for a path placeholder name repeated in a path, for two paths
  that differ only in names, and for a query key or static segment common
  clients do not send as written (`_sent_as_written`: a query key of
  letters, digits and `-._`; a segment of `pchar`, `%` only before two
  hexadecimal digits, not `.` or `..`). `document` and `operations` are
  the application's additions, JSON objects merged as written
  (`_openapi.mojo`'s `_merge`); one that names no route or repeats a
  derived member raises.
- Opt-in: `_route` stores the operation only under `-D MUNTIN_OPENAPI`
  (`is_defined`), and `openapi` does not compile without it; a file's
  `# Build flags (scripts/build_one.sh): ` line passes the define.
- `src/muntin/json.mojo`, too: `JsonWriter._copy` writes a parsed
  `JsonValue` (a number keeps its literal), `JsonWriter._holds`,
  `JsonValue._name`.
- `tests/test_spike_openapi.mojo` and `tests/openapi_spike_handlers.mojo`:
  the spike (10 tests). Its `Param` handler is in its own module: on Mojo
  1.1.0, on the base too, a module whose `__functions_in_module()` holds a
  function taking a `Param` crashes the compiler (as
  `tests/named_value_handlers.mojo` avoids).
- `tests/openapi_api_fail/` (built by `check.sh`): a `Group`'s `openapi`
  does not compile, nor an `App`'s without the define.

Revised after review on the pull request: a `Json[T]` result is the
`2XX` response, not `default` (which also covered Muntin's own 400, 413,
415 and 500); every route string, optional ones too, has `minLength: 1`;
the encoded-name refusals; the spike asserts a carried binary body and
Muntin's own answers. Revised again after the review of those fixes: `~`
refused in a query key (a form serializer encodes it), `.` and `..`
segments refused, and a test of the character classes' boundaries.

Revised after the adversarial review on the pull request: an optional
query value has `allowEmptyValue` (an empty value is `None`); a request
body is `required` only for `Json[T]`; integers carry `Int`'s bounds; a
segment may hold `%HH`; the application's additions (`document`,
`operations`), which the spike's document uses for the guard's
credential and the 404 and 204 answers; the opt-in define.

With `MUNTIN_OPENAPI_OUT=<dir>`, the spike writes its document and each
exchange it sent; `validate_openapi.py` checks them (its docstring):
`MUNTIN_OPENAPI_OUT=<dir> ./scripts/test.sh tests/test_spike_openapi.mojo`,
then `python3 prototype-m3-091/validate_openapi.py <dir>` with
`openapi-spec-validator` and `jsonschema` installed. At this commit: a
valid document of 20 operations; 40 exchanges, 38 agree with it, 2 show
their known gap (`1.0` as an `Int`, a hand-written reader's `{}`), 0
mismatch.

Reproduce from this commit's root (Linux, pixi): `./scripts/check.sh`,
`./scripts/test.sh`, `SANITIZE=address ./scripts/test.sh
tests/test_spike_openapi.mojo`, `./scripts/check_flare.sh`.
