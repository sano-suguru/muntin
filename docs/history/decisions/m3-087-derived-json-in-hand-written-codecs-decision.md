# Derived JSON values inside hand-written codecs decision (M3-087)

> **Current.** Not built yet: its "Next production slice" is M3-088.

Status: **decision** (M3-087, issue [#195](https://github.com/sano-suguru/muntin/issues/195)). Evidence: the pull request. Changes part of M3-075 and M3-082 (below).

**Question and what settles it.** A hand-written `write_json` cannot write a `JsonFields` value and a hand-written `from_json` has no derived reader, so a type needing one special member writes every nested DTO by hand again: the drift [M3-082](m3-082-derived-json-codecs-decision.md) removed. Through what Muntin-owned API does a hand-written codec read and write a derived value, with which kinds, how is a bad field refused, and does a read keep its member path ([M3-084](m3-084-request-rejection-report-decision.md))? Settled by Mojo 1.1.0 probes of the overload sets; a scratch copy of production passing `check.sh`, `test.sh` (under AddressSanitizer too) and `check_flare.sh` with a spike through `TestClient`; the refusal measured; and a fresh-context review.

**Choice: `JsonValue.read[T]` and `JsonFields` overloads of `JsonWriter.value` and `field`, both by the derived rules.**

```mojo
def from_json(value: JsonValue) raises -> Self:
    if value["v"].int() != 2:
        raise Error("unsupported version")
    return Self(value.read[Place]("place"))   # also read[T]() for the value

def write_json(self, mut out: JsonWriter) raises:
    out.begin_object()
    out.field("v", 2)
    out.field("place", self.place)            # a JsonFields struct
    out.end_object()
```

- `read` takes any kind a derived field takes; a member reads as a derived field of that name (absent or `null`: an empty `Optional`). A failure's message starts with the path below the value; each hand-written boundary adds its own `: ` (`env: place.city: ...`).
- `value` and `field` add a `JsonFields` struct and an `Optional` or `List` of one, except for a `ToJson` type, whose writer takes over (both match: ambiguous). M3-075's set and one-level limit are otherwise unchanged.
- A bad field fails the build when a route or call instantiates the codec, naming the innermost field, the hand-written call in the chain: a `where` clause cannot call the refusal. An unused codec builds.

**Rejected.**
- One generic `value`/`field` per method for every derived kind (the first prototype, `ef42306`): it lifts M3-075's one-level limit, but an unsupported `Iterable` (`Dict`) then fails late, not `no matching method`.
- A default `write_json` on `JsonFields`: as M3-082, registration cannot tell it from a hand-written one.
- Joined paths (`env.place.city`): `from_json` raises `Error`; a path needs M3-084's deferred typed error.
- A `JsonValue` carrying its path: a string per access, on success too.

**Revisit when** a hand-written member's path must join its parent's; a `where` clause can call a function (`json_known_gaps/hand_written_derived_unused_codec_builds` stops building); nested containers in `field`.

**Next production slice (M3-088):** the prototype at `c7a38cf` (its `prototype-m3-087/README.md`).
- Code: as prototyped.
- Tests: the spike's cases in `tests/test_derived_json.mojo`, under `SANITIZE=address`; its fixtures; `json_api_fail/derived_inside_hand_written_writer.mojo` retired; the whole-output comparison; a revisit index row.
- Docs: bodies and responses references, `docs/ARCHITECTURE.md`, `docs/SPEC.md`.
- Not in the slice: joined paths, nested containers in `field`, renamed or defaulted members ([#196](https://github.com/sano-suguru/muntin/issues/196)).
