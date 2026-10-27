# M3-098 prototype, revised twice (evidence for its pull request, not for merging)

Base: `fb04dda` (main when the pull request was opened). The commit of this
prototype is the one the decision record's "Next production slice" names;
the pull request's next commit removes it again, so `src/muntin` is
unchanged when the decision merges.

Revised after the owner's review of the first prototype (`e2c4f8a`): the
scope is renaming and defaults only (no new number kinds), and a default is
no longer a field of a whole `json_default() -> Self` value, which needed a
placeholder for every required member. Revised again after the owner's
review of `ea9e056`: camelCase keeps non-ASCII characters (it read UTF-8
byte by byte, so `café_name` became `cafÃ©Name`), and an explicit
`name=""` is refused instead of being taken for no name.

What changed against the base:

- `src/muntin/json.mojo`:
  - Two refinements of `JsonFields`: `JsonMembers`, which requires
    `json_members() -> List[JsonMember]` (no provided default, so a
    misspelt or non-static one fails conformance), evaluated at compile
    time; and `JsonCamelCase`, a marker.
    `JsonMember(field, name=)` renames, `JsonMember(field, default=)`
    gives an absent member a default as JSON text, and
    `JsonMember(field, name=, default=)` does both; there is no
    initializer without either, and `named` records a given name.
  - `_camel`: cuts only at the ASCII `_` and letter it changes, so every
    other byte, UTF-8 included, is kept.
  - `_wire[T, i]`: a member's name (its `json_members` name, else its
    camelCase form for `JsonCamelCase`, else the field's), a compile-time
    value; the writer, the reader, the member path and `_write_schema` use
    it.
  - `_members_refusal[T]`: the refusal of an inconsistent declaration
    (an unknown or repeated field, an empty member name, two fields with
    one member name), checked first by `_kind_ok` and
    `_innermost`.
  - `_default_refusal[T]`, where `T` is read: no application code runs at
    compile time. A default of a field that Muntin's own readers read
    alone (`_plain`: an `Int`, `Float64`, `Bool`, `String`, or a `List` or
    `Optional` of one) is read as that field at compile time (`_reads_as`);
    any other `List`'s default must be `[]` and any other `Optional`'s
    `null` (`_empty_kind`, `_is_empty`), which build no element; a default
    of any other field (a `JsonFields` struct, a hand-written `FromJson`)
    is refused.
  - `_Members[T].member`: an absent defaulted member is its default's
    text, parsed and read by the field's rules on each read that lacks it.
  - The read schema leaves defaulted members out of `required`.
- `src/muntin/__init__.mojo`: exports `JsonCamelCase`, `JsonMember`,
  `JsonMembers`.
- `tests/test_spike_json_members.mojo`: the spike (8 tests, one with non-ASCII
  names read, written and in schemas).
- `tests/json_api_fail/members_*.mojo`: twelve refusals, three of them
  Mojo's errors: a non-static and a misspelt `json_members` (conformance)
  and an entry with neither name nor default (no initializer).

Reproduce from this commit's root (Linux, pixi): `./scripts/check.sh`,
`./scripts/test.sh` (the spike included), `SANITIZE=address
./scripts/test.sh tests/test_spike_json_members.mojo`,
`./scripts/check_flare.sh`.
