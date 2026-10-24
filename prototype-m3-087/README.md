# M3-087 prototype (evidence for its pull request, not for merging)

Base: `27743e4` (main when the pull request was opened). The commit of
this prototype is the one the decision record's "Next production slice"
names; the pull request's next commit removes it again, so `src/muntin` is
unchanged when the decision merges.

What changed against the base (revised after review: the first prototype,
`ef42306`, replaced the `[T: ToJson]` `List` and `Optional` overloads with
one generic overload per method, which lifted M3-075's one-level limit but
made an unsupported `Iterable` fail late; this one only adds overloads):

- `src/muntin/json.mojo`:
  - `JsonValue.read[T]()` and `read[T](name)`: the derived reader for
    any derived kind, a failure's message prefixed with the member path
    below the value; `_read_named`, the one member rule that the derived
    `_read_member` and `read[T](name)` share.
  - `JsonWriter.value` and `field`: three overloads each for a `JsonFields`
    struct, an `Optional` and a `List` of one, `where not conforms_to(T,
    ToJson)` (else a type that is both is ambiguous), writing through
    `_write_value` after a `comptime assert` of `_call_refusal`. The
    overload comment follows.
  - `_call_refusal`: the refusal of those calls, naming the innermost
    field, else the type itself (not `Json[T]`).
- `tests/test_spike_derived_in_hand_written.mojo`: the spike (5 tests).
- `tests/json_api_fail/derived_inside_hand_written_writer.mojo` removed (it
  builds now); three `hand_written_derived_*` must-not-build fixtures and
  `tests/json_known_gaps/hand_written_derived_unused_codec_builds.mojo`
  added.

Reproduce from this commit's root (Linux, pixi): `./scripts/check.sh`,
`./scripts/test.sh` (the spike included), `SANITIZE=address
./scripts/test.sh tests/test_spike_derived_in_hand_written.mojo`,
`./scripts/check_flare.sh`.
