# M3-087 prototype (evidence for its pull request, not for merging)

Base: `27743e4` (main when the pull request was opened). The commit of
this prototype is the one the decision record's "Next production slice"
names; the pull request's next commit removes it again, so `src/muntin` is
unchanged when the decision merges.

What changed against the base:

- `src/muntin/json.mojo`:
  - `JsonValue.read[T]()` and `read[T](name)`: the derived reader for
    any derived kind, a failure's message prefixed with the member path
    below the value; `_read_named`, the one member rule that the derived
    `_read_member` and `read[T](name)` share.
  - `JsonWriter.value` and `field`: one generic overload each, `where
    not conforms_to(T, ToJson) and (conforms_to(T, JsonFields) or
    conforms_to(T, Iterable))`, writing through `_write_value`; it
    replaces the `[T: ToJson]` `Optional` and `List` overloads. The
    `ToJson` `field` calls `write_json` itself (forwarding to `value`
    is ambiguous inside the generic). The overload comment follows.
  - `_call_refusal`: the refusal of those calls, naming the innermost
    field, else the type itself (not `Json[T]`).
- `tests/test_spike_derived_in_hand_written.mojo`: the spike (4 tests).
- `tests/json_api_fail/`: `derived_inside_hand_written_writer`,
  `field_list_of_lists`, `field_list_of_optionals` and
  `field_optional_of_list` removed (they build now; the spike writes their
  kinds); four `hand_written_derived_*` must-not-build fixtures added.

Reproduce from this commit's root (Linux, pixi): `./scripts/check.sh`,
`./scripts/test.sh` (the spike included), `SANITIZE=address
./scripts/test.sh tests/test_spike_derived_in_hand_written.mojo`,
`./scripts/check_flare.sh`.
