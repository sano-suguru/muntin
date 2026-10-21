# M3-082 prototype (evidence for pull request #187, not for merging)

Base: `66dd883` (main when #187 was opened). The prototype that the decision
record's "Next production slice" calls "as prototyped" is the commit of this
branch that the record names.

What changed against the base:

- `src/muntin/json.mojo`: `JsonFields`; `_kind_ok`, `_refusal` (per direction);
  `_write_value`, `_read_value`, `_read_member`, `_read_list`, `_as_list`,
  `_as_optional`; `Json[T]`'s conformances widened to `JsonFields` and
  `Iterable`; `_JsonBody` gains `_read_refusal` and `_write_refusal`.
- `src/muntin/_handler_storage.mojo`: `_build_record` generic over its two
  borrowed sources and bound by `_FieldBuilt`; no field required.
- `src/muntin/_field_built.mojo` (new): `_FieldBuilt`, refined by
  `RouteValues` (`route_value.mojo`) and `JsonFields` only.
- `src/muntin/_rebind.mojo` (new): `_as` (moved from `app.mojo`) and `_view`,
  the only rebinds, each after `comptime assert A == T`.
- `src/muntin/_registration_rules.mojo`: `_json_ok` in `_admits` and
  `_check_json` in `_check`, one per slot and for the result.
- `src/muntin/headers_body.mojo`: `WithHeaders` forwards the refusals.
- `scripts/check_unsafe.sh`: the boundary above enforced (see its comments).
- `tests/test_spike_derived_json.mojo`: the spike (8 tests).
- `tests/json_api_fail/derived_*.mojo`: the 8 refusals, checked by `check.sh`.
- `prototype-m3-082/`: this file; `run.sh`, which runs every step below and
  exits 1 naming each failed one; `check_unsafe_mutations.sh`, which plants
  16 boundary violations and requires each to fail `check_unsafe.sh` with its
  rule's error; and `check_probes.sh`, which builds each of `probes/` (the
  Mojo 1.1.0 behaviors the decision rests on) and compares the outcome with
  its `# Expect:` and `# Expect-output:` lines.

Reproduce: `./prototype-m3-082/run.sh` from the repository root (Linux, pixi).
