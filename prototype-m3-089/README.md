# M3-089 prototype (evidence for its pull request, not for merging)

Base: `b51d94b` (main when the pull request was opened). The commit of
this prototype is the one the decision record's "Next production slice"
names; the pull request's next commit removes it again, so `src/muntin` is
unchanged when the decision merges.

What changed against the base:

- `src/muntin/body.mojo`: `FromBody` gains `comptime max_bytes: Int =
  1_048_576` and its contract.
- `src/muntin/json.mojo`: `Json[T, *, limit: Int = _MAX_BODY_BYTES]`,
  whose `max_bytes` is `limit`; `_parse_json` takes the limit, so
  `from_body` and `_from_text` raise above it.
- `src/muntin/headers_body.mojo`: `_HeaderCarrier._max_bytes()` returns a
  carried `FromBody`'s `max_bytes` too.
- `src/muntin/app.mojo`: `_json_status` compares with `_body_limit[B]()`
  (the carrier's, or the body type's `max_bytes`); `_slot`'s bare
  `FromBody` branch answers 413 over `A.max_bytes` before the UTF-8 read.
- `src/muntin/_registration_rules.mojo`: `_kind` gives a `FromBody` with a
  negative `max_bytes` `_NEGATIVE_LIMIT`; the message says "a body type's".
- `tests/bytes_limit_api_fail/negative_limit*.mojo`: the expected message.
- `tests/body_limit_api_fail/` (built by `check.sh`): five must-not-build
  fixtures.
- `tests/test_spike_body_limits.mojo`: the spike (7 tests).

Expected failures in `test.sh` (tests that pin the base's "text bodies have
no Muntin limit"; production rewrites them): `tests/test_bytes_limit.mojo`
`test_text_json_raw_and_unlimited_routes_are_unchanged` (its `/note` type
declares `max_bytes = 4`, which the base ignores), `tests/test_json.mojo`
`test_non_json_bodies_are_unchanged_and_uncapped` and
`tests/test_spike_json.mojo` `test_body_size_cap` (a text body of 1 MiB + 1).

Reproduce from this commit's root (Linux, pixi): `./scripts/check.sh`,
`./scripts/test.sh`, `SANITIZE=address ./scripts/test.sh
tests/test_spike_body_limits.mojo`, `./scripts/check_flare.sh`.
