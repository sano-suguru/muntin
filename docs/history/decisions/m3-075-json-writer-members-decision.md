# JSON writer members decision (M3-075)

> **Current.** Now described in [responses reference, "Writing a `ToJson` type"](../../reference/responses.md#writing-a-tojson-type).
> Changed in part since:
> - [M3-087](m3-087-derived-json-in-hand-written-codecs-decision.md) (not built yet, M3-088): `field` and `value` also take a `JsonFields` struct, or an `Optional` or `List` of one, whose bad field fails when the codec is instantiated, not where it is called.

Status: **decision and production** (M3-075, pull request #162, with its probes and measurements).

**Question and what settles it.** A `write_json` takes two calls per object member (`out.name("id")`, `out.int(self.id)`), a method chosen by the field's type, and four lines for an `Optional` or a `List` field: 27 lines for the 8 members of `tests/test_json.mojo`'s `User`. Can one call, chosen by the value's type, write a member, with no new failure path or late diagnostic and no existing `write_json` changed? Settled by every kind written as the explicit calls write it, and an unsupported type failing at its call (Mojo 1.1.0).

**Choice: `JsonWriter.field(name, value)` and `JsonWriter.value(value)`, overloaded on the value's type.** Each takes Int, Float64, Bool, String, a `ToJson` type, and an `Optional` (empty: `null`) or a `List` (an array) of one of those; `field` is `name(name)` then `value(value)`. They call the existing methods, which stay, so the structure rules and the fixed 500 are unchanged. A type outside the set fails where it is called, `no matching method in call to 'field'` (`json_api_fail/field_without_to_json`, `field_list_of_lists`), not deep in an instantiation as [M3-008](m3-008-json-codec-decision.md)'s derived encoder would. A `ToJson` element is written by index, so a move-only one works (`List` iteration requires `Copyable`).
- Cost: 29 new public overloads (15 `value` with the existing one, 15 `field`). One level of nesting: `List[List[Int]]` and `Optional[List[...]]` keep the explicit loop. A numeric list literal or `[]` is ambiguous (`json_api_fail/field_*_list_literal`). Other widths (`Int64`, `Float32`) convert first, as with `int()`.

**Rejected.**
- One generic `value[T]` whose `Optional`/`List` overloads forward to the element's overload: on Mojo 1.1.0 the call resolves to the generic `Optional` overload itself, by implicit conversion, not to the element's (`json_api_fail/generic_writer_forwarding`).
- A `comptime if T == Int` dispatch over `AnyType`: needs `rebind`, which M3-008 keeps out of the codec, and fails late on an unsupported type.
- Scoped objects (`with out.object():`): the manager would hold the writer the body writes to.
- A derived `write_json`: still M3-008's revisit condition (reflection, late diagnostics).

**Revisit when:**
- `json_api_fail/generic_writer_forwarding` builds and prints `int`: collapse the `Optional`/`List` overloads into generic ones;
- a derived `write_json` lands (M3-008): `field` stays the hand-written form beside it;
- the reader side (`from_json`) gets the same treatment: its own decision.

**Next production slice (M3-075, in this item).**
- Code: `src/muntin/json.mojo`, the overloads on `JsonWriter`.
- Tests: `tests/test_json_fields.mojo`; `tests/json_api_fail/field_*.mojo`, `generic_writer_forwarding.mojo`.
- Docs: `docs/reference/responses.md` and the JSON examples in `docs/reference/bodies.md` and `docs/GUIDE.md`; `docs/ARCHITECTURE.md` (revisit index); `docs/SPEC.md`.
- Not in the slice: the reader side, nested containers, top-level `List` results (#141).
