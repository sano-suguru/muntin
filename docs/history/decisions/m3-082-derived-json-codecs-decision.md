# Derived JSON codecs decision (M3-082)

> **Current.** Built by M3-083. Now described in [bodies reference, "JSON (`Json[T]`)"](../../reference/bodies.md#json-jsont), [responses reference, "JSON results"](../../reference/responses.md#json-results) and [ARCHITECTURE, "JSON"](../../ARCHITECTURE.md#json).
> Changed in part since:
> - [M3-084](m3-084-request-rejection-report-decision.md): a derived decoder's failure message names the member path, which the 400's `Rejection` reports.

Status: **decision** (M3-082, #187, issue [#141](https://github.com/sano-suguru/muntin/issues/141)). Evidence: the pull request.

**Question and what settles it.** A DTO's members are mapped by hand twice, in `from_json` and `write_json`, so a new field compiles and is silently left out (#167's `tag`). [M3-008](m3-008-json-codec-decision.md) deferred derived codecs on Mojo 1.1.0: `List[<struct>]` was not reachable without `__extension`, an unsupported field failed only deep in instantiation, and decoding had no constructor. Can Muntin, on the pinned Mojo 1.1.0 with documented features, derive both directions from a struct's fields for scalars, `String`, `Optional`, `List` and nested DTOs, refuse an unsupported field with a message at registration, keep hand-written `FromJson`/`ToJson` ([M3-075](m3-075-json-writer-members-decision.md)) for special representations, and answer a top-level `List` result? Settled by probes of each of M3-008's three blockers; a scratch copy of production with the derived codec passing `check.sh` and `test.sh` unchanged, its decoding failures under AddressSanitizer with leak detection, and the unsupported-field diagnostic measured against the registration rules'; and a fresh-context review. Code generation is the alternative compared. If a blocker stands, the item records a deferral instead.

**Choice: `JsonFields`, a public marker trait: the struct is a JSON object, one member per field, named after it.**

```mojo
@fieldwise_init
struct NewNote(JsonFields):
    var text: String
    var tag: String

def create_note(body: Json[NewNote]) -> Json[Note]: ...
def list_notes() -> Json[List[Note]]: ...
```

- Fields: `Int`, `Float64`, `Bool`, `String`, a `FromJson` (read) or `ToJson` (written) type, a `JsonFields` struct, or a `List` or `Optional` (not of an `Optional`) of one. An `Optional` may be absent or `null`; other members are required, unknown ones ignored. A struct with no field is `{}`: JSON allows it and building it writes nothing. `Json[T]` also takes a top-level `List` or `Optional`.
- A hand-written `FromJson` or `ToJson` on the struct takes that direction over.
- The registration rules refuse an unsupported field, naming it; a raw `from_body` gets it from the codec (a `where` clause cannot call a function).
- Built by [M3-061](m3-061-route-value-records-decision.md)'s `_build_record`: `__init__` never runs; a failure destroys each built field once. `conforms_to(F, Iterable)` yields the element type; `F == List[E]` is asserted before each rebind.

**Rejected.**
- Defaults on `FromJson`/`ToJson`: registration cannot tell them from hand-written ones, so a bad field fails deep in instantiation.
- M3-008's refining-trait default: undocumented.
- A trait-default `__init__(out self)` assigning through `field_ref`: destroys the uninitialized old value.
- Code generation: a Mojo parser and a build step, drift when not re-run.

**Revisit when** Mojo gains a reflective constructor, `where` clauses can call functions, or the element type stops resolving; or applications need renamed or defaulted members, or a bare DTO body.

**Next production slice (M3-083), after M3-081 merges (both edit `app.mojo` and `_registration_rules.mojo`):** the prototype at `3d1e4be` (branch `claude/project-thread-h9ut1m-prototype`, its `prototype-m3-082/README.md`), which passes `check.sh` unchanged.
- Code: as prototyped, and `json.mojo`'s docstring. `_build_record` takes any `_FieldBuilt`, which only `RouteValues` and `JsonFields` refine; the rebinds move to `_rebind.mojo`; `check_unsafe.sh` enforces both, and M3-015's text follows. Exports `JsonFields`.
- Tests: the prototype's spike under `SANITIZE=address` and its `json_api_fail/derived_*`, each naming the innermost field; the whole-output diagnostic comparison; build times; a loopback request.
- Docs: references, guide, `docs/ARCHITECTURE.md`, `docs/SPEC.md`.
- Not in the slice: derived types inside hand-written codecs, other kinds (`Dict`).
