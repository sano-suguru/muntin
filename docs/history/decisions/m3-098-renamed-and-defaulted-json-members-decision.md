# Renamed and defaulted derived JSON members decision (M3-098)

> **Current.** Not built yet: its "Next production slice" is M3-099.

Status: **decision** (M3-098, issue [#196](https://github.com/sano-suguru/muntin/issues/196)). Evidence: its pull request, [#208](https://github.com/sano-suguru/muntin/pull/208). Changes part of M3-082 and M3-087 (below).

**Question and what settles it.** A `JsonFields` member is named after its field, with no renaming or default, and its kinds are fixed ([M3-082](m3-082-derived-json-codecs-decision.md)), so `createdAt` for `created_at`, an omitted member with a default, or a narrower number forces a hand-written direction; Mojo 1.1.0 fields carry no metadata. Through what Muntin-owned API, on documented features, are members renamed and defaulted, which more kinds (widths, `Dict`, `Optional[Optional[T]]`) are taken, how is a bad declaration refused at registration, and do the member path, `read[T]` and the schema follow the names? Settled by Mojo 1.1.0 probes; a scratch copy of production passing `check.sh`, `test.sh` (under AddressSanitizer too) and `check_flare.sh` with a spike through `TestClient`; each refusal measured; a fresh-context review.

**Choice: three refinements of `JsonFields`, each requiring its method, and more number kinds.**

```mojo
@fieldwise_init
struct Query(JsonCamelCase, JsonDefault, JsonMembers):
    var created_at: String                  # member createdAt
    var kind: String                        # member type
    var limit: Int                          # may be absent: 20

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("kind", name="type"), JsonMember("limit", default=True)]

    @staticmethod
    def json_default() -> Self:
        return Self("", "", 20)
```

- A member is named by `json_members`, else camelCased under `JsonCamelCase`, else after its field; reading, writing, failure paths, `read[T]` and schemas use that name.
- An absent defaulted member copies that field of `json_default()`, called once per read lacking one; `null` is not absent. A read schema does not require it.
- `json_members` runs at compile time. Registration refuses, naming the entry, a missing or repeated field, an entry with neither name nor default, two fields with one name, and a default outside `JsonDefault` or of a non-`Copyable` type. A missing or misdeclared method fails conformance.
- Fields also take `UInt`, `Int8`–`Int64`, `UInt8`–`UInt64` (exact, range-checked) and `Float32` (through `Float64`, finite); `JsonWriter.field` does not ([M3-075](m3-075-json-writer-members-decision.md)).

**Rejected.**
- Provided `json_members` on `JsonFields`: a misspelt or non-static override builds and is ignored.
- Overriding a trait's `comptime` member: documented only as a constant shared by every conforming type.
- Field wrappers (`Renamed["createdAt", String]`): every use of the field changes.
- A struct-wide default: a misspelt required member is silently defaulted.
- `Dict[String, V]`: generic code reaches `V` only through private stdlib fields.
- `Optional[Optional[T]]`: needs a writer that omits members; stays in #196.

**Revisit when** Mojo documents field attributes or overriding a trait's `comptime`, or exposes a `Dict`'s value type; an application needs absent and `null` apart, another case, `Float32` rounded directly, or widths in a hand-written writer.

**Next production slice (M3-099):** the prototype at `e2c4f8a` (its `prototype-m3-098/README.md`).
- Code: as prototyped, and `json.mojo`'s docstring; four new exports.
- Tests: the spike's cases in `tests/test_derived_json.mojo`, under `SANITIZE=address`; the `json_api_fail/members_*` and retargeted fixtures; the whole-output comparison; `tests/test_openapi.mojo` with a renamed and a defaulted member, validated.
- Docs: bodies, responses and OpenAPI references, `docs/ARCHITECTURE.md`, `docs/SPEC.md`.
- Not in the slice: `Dict`, `Optional[Optional[T]]`, a schema `default`.
