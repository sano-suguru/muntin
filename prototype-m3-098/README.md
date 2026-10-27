# M3-098 prototype (evidence for its pull request, not for merging)

Base: `fb04dda` (main when the pull request was opened). The commit of this
prototype is the one the decision record's "Next production slice" names;
the pull request's next commit removes it again, so `src/muntin` is
unchanged when the decision merges.

What changed against the base:

- `src/muntin/json.mojo`:
  - Three refinements of `JsonFields`, each requiring its method (no
    provided default, so a misspelt or non-static one fails conformance):
    `JsonMembers` (`json_members() -> List[JsonMember]`, evaluated at
    compile time), `JsonCamelCase` (a marker) and `JsonDefault`
    (`json_default() -> Self`); `JsonMember(field, name=, default=)`.
    (The first version, reviewed, used provided `json_case()` and
    `json_members()` methods on `JsonFields`; a wrong override built and
    was ignored.)
  - `_wire[T, i]`: a member's name (its `json_members` name, else its
    camelCase form for `JsonCamelCase`, else the field's), a compile-time
    value; the writer, the reader, the member path and `_write_schema` use
    it.
  - `_members_refusal[T]`: the registration refusal of an inconsistent
    declaration, checked first by `_kind_ok` and `_innermost`.
  - `_Members[T]`: the context `_build_record` passes to each field's
    reader, the member names and `T.json_default()`, built once when a
    defaulted member is absent; an absent defaulted member is a copy of
    that field of it.
  - `_width`, `_read_width`, `_write_width`: `UInt`, `Int8` to `Int64`,
    `UInt8` to `UInt64` and `Float32` fields (and `JsonValue.read` of them);
    `JsonWriter._number` writes a formatted literal (`UInt64` above
    `Int.MAX`, `Float32`'s shortest form).
  - The unsupported-kind refusals list the new kinds.
- `src/muntin/__init__.mojo`: exports `JsonCamelCase`, `JsonDefault`,
  `JsonMember`, `JsonMembers`.
- `tests/test_spike_json_members.mojo`: the spike (8 tests).
- `tests/json_api_fail/members_*.mojo`: nine refusals, two of them the
  conformance errors of a non-static and a misspelt `json_members`.
- Eleven `tests/json_api_fail/derived_*` and `hand_written_derived_*`
  fixtures used `UInt8`, `Int64` or `Float32` as the unsupported type; they
  use `Float16` now, with the same refusal;
  `hand_written_derived_read_unsupported_kind`'s expected text lists the
  new kinds.

Reproduce from this commit's root (Linux, pixi): `./scripts/check.sh`,
`./scripts/test.sh` (the spike included), `SANITIZE=address
./scripts/test.sh tests/test_spike_json_members.mojo`,
`./scripts/check_flare.sh`.
