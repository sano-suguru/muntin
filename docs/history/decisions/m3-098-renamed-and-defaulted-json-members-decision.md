# Renamed and defaulted derived JSON members decision (M3-098)

> **Current.** Not built yet: its "Next production slice" is M3-099.

Status: **decision** (M3-098, issue [#196](https://github.com/sano-suguru/muntin/issues/196)). Evidence: its pull request, [#208](https://github.com/sano-suguru/muntin/pull/208). Changes part of M3-082 (below).

**Question and what settles it.** A `JsonFields` member is named after its field, with no renaming or default, and its kinds are fixed ([M3-082](m3-082-derived-json-codecs-decision.md)), so `createdAt` for `created_at`, an omitted member with a default, or a narrower number forces a hand-written direction; Mojo 1.1.0 fields carry no metadata. Through what Muntin-owned API, on documented features, are members renamed and defaulted, which more kinds (widths, `Dict`, `Optional[Optional[T]]`) are taken, how is a bad declaration refused at registration, and do the member path, `read[T]` and the schema follow the names? Settled by Mojo 1.1.0 probes; a scratch copy of production with a spike through `TestClient` passing `check.sh`, `test.sh` (under AddressSanitizer too), `check_flare.sh` and CI; each refusal measured; fresh-context reviews.

**Choice: two refinements of `JsonFields`; a default is JSON text, read by its field's rules at compile time.**

```mojo
@fieldwise_init
struct Query(JsonCamelCase, JsonMembers):
    var user_id: String                     # member userId, required
    var kind: String                        # member type
    var limit: Int                          # may be absent: 100

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("kind", name="type"), JsonMember("limit", default="100")]
```

- A member is named by `json_members`, which wins over `JsonCamelCase`'s rule (`created_at` is `createdAt`, `café_name` `caféName`), else after its field; reading, writing, failure paths, `read[T]` and schemas use that name.
- An absent defaulted member is read from its text, on each read; `null` is not absent (an `Optional` reads it as empty). A read schema does not require it. Required members need no value.
- No application code runs at compile time: a default is for an `Int`, `Float64`, `Bool`, `String`, or a `List` or `Optional` of one; any other `List`'s is `[]`, `Optional`'s `null`.
- A misspelt or non-static `json_members` fails conformance; a `JsonMember` takes `name`, `default` or both. Registration refuses, naming the entry: a missing or repeated field, an empty name, two fields with one final name, and a default that breaks the rule above or its field does not read.

**Rejected.**
- `json_default() -> Self` (the first prototype): required members need placeholders, which some types lack.
- Typed `default=20`: a `String` default would be text or a value.
- Provided `json_members` on `JsonFields`: a misspelt or non-static override builds and is ignored.
- Overriding a trait's `comptime`: documented only as a shared constant.
- Field wrappers (`Renamed["createdAt", String]`): every use changes.
- A struct-wide default: a misspelt required member is silently defaulted.
- New number kinds, `Dict[String, V]` (`V` is only in private stdlib fields) and `Optional[Optional[T]]` (absent, `null` and omission apart): separate items in #196.

**Revisit when** Mojo documents field attributes or overriding a trait's `comptime`; a default must be computed at run time or be of another type; an application needs another case.

**Next production slice (M3-099):** the prototype at `e791c78` (its `prototype-m3-098/README.md`).
- Code: as prototyped, and `json.mojo`'s docstring; three new exports.
- Tests: the spike's cases (non-ASCII names too) in `tests/test_derived_json.mojo`, under `SANITIZE=address`; the `json_api_fail/members_*` fixtures; the whole-output comparison; `tests/test_openapi.mojo` with a renamed and a defaulted member, validated.
- Docs: bodies, responses and OpenAPI references, `docs/ARCHITECTURE.md`, `docs/SPEC.md`.
- Not in the slice: a schema `default`, the kinds above.
