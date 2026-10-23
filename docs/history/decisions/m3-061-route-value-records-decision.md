# Route-value records decision (M3-061)

> **Current.** Now described in [route-values reference, "Route-value records"](../../reference/route-values.md#route-value-records), [ARCHITECTURE, "Registration surface"](../../ARCHITECTURE.md#registration-surface) and [ARCHITECTURE, "Storage and ownership"](../../ARCHITECTURE.md#storage-and-ownership).
> Changed in part since:
> - [M3-065](m3-065-request-context-storage-decision.md): the Context[T] slots reserved in the shape order were withdrawn with M3-063's context API.
> - [M3-082](m3-082-derived-json-codecs-decision.md), built by M3-083: `_build_record` builds any `_FieldBuilt`, which `RouteValues` and `JsonFields` alone refine.
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

Status: **decision** (M3-061, pull request #112; `src/muntin` unchanged). The two prototypes, the record prototype's patch on `29519e8`, its runs, the probes, the candidate-note counts and the build times are in the pull request.

**Question and what settles it.** A typed handler takes at most two route values ([M3-022](m3-022-several-route-values-decision.md)), so `/organizations/{org_id}/projects/{project_id}/tasks/{task_id}` reaches no typed handler. A third value beside a body or `Headers` needs slot arity 4, ten more overloads, which [M3-052](m3-052-registration-complexity-budget-decision.md) admits only against a slot kind carrying several values. How does a handler take three or more? Settled by two prototypes, slot arity 4 and a record slot kind, each with the suites, AddressSanitizer, probes, note counts and cold builds.

**Choice: `RouteValues`, a public marker trait. A struct that conforms to it is one request slot carrying every route value of its route: one field per placeholder, in the literal's order, each named after the placeholder it binds.**

```mojo
@fieldwise_init
struct TaskAt(RouteValues):
    var org_id: Int
    var project_id: Int
    var task_id: Int

def get_task(at: TaskAt) -> Json[Task]: ...
def update_task(db: State[Db], at: TaskAt, body: Json[TaskEdit]) raises -> Json[Task]: ...

comptime TASK = "/organizations/{org_id}/projects/{project_id}/tasks/{task_id}"
app.get[TASK](get_task)
app.patch[TASK](update_task, db)
```

This is M3-022's candidate D, rejected then for a struct per route, a second binding system and unsafe writes outside the storage module. Now three values are required and their other form costs ten overloads; the writes are one generic helper in `_handler_storage.mojo`, given the conversion as a parameter (M2-006 holds); and the record is opt-in past two values, every name checked.

- **Contract.** Conforming to `RouteValues` consents to Muntin initializing the fields directly: the record's `__init__` never runs, so neither it nor an invariant across fields (`start_id <= end_id`) is enforced. A field's validation belongs in its type (`FromRouteValue`), a check across fields in the handler. The destructor runs once for a completed record, never for a partial one, and must not rely on anything only `__init__` establishes. Mojo 1.1.0's `reflect[T]` shows fields, not initializers, so a record with its own `__init__` cannot be refused (a probe's aborting one never ran); this is the record's first documented limit.
- **Shapes.** Request slots go `State[S]`, then any `Context[T]` slots if the request-context decision (pull request #113) is accepted, then the record as the only route value, then at most a body or `Headers`: `def(P)`, `def(P, Headers)` on `get`, `delete` and bodyless `post`, `put` and `patch`, `def(P, B)` on `post`, `put` and `patch`. A record is one slot whatever its field count, so it carries several route values independently of the slot-count limit; arity 3 still caps the slots. Not accepted: a body and `Headers` together (no shape has both; `def(P, WithHeaders[B])` does), a record beside a bare value or another record, two `Context` slots with a record and a body (arity 4), and a record in a raw handler.
- **Positions.** A slot's first raw value is at the sum of the widths of the slots before it: a bare value 1, a record its field count, a `Context`, body or `Headers` 0. One function holds the widths; whichever of M3-062 and the request-context slice lands later extends it, and a `Context` after a record gets that decision's order message.
- **Fields.** Each is a bare route-value type (`Int`, `String`, a `FromRouteValue` type, or `Optional[Int]` or `Optional[String]` at a query position, M3-024). Field `i` binds placeholder `i` (path placeholders left to right, then query ones); the counts are equal, the placeholder names distinct, and each field's name equals its placeholder's (`{org-id}` is a backquoted field), so a swap is a compile error naming both.
- **Conversion and errors.** Each field converts as a bare slot of its type, in field order: the first invalid value is 400 and nothing after it, the body included, is converted. No new status.
- **Construction.** The helper writes each converted field into `MaybeUninit[T]` at `reflect[T].field_offset[index=i]()` as its own type, so alignment and padding are the compiler's, and refines field types with `conforms_to`, not `downcast`, which Mojo 1.1.0 does not check. Its invariant: nothing is destroyed before field 0 is written; after `k` fields, exactly fields `0` to `k-1` are initialized; when field `k` fails, each of them is destroyed once, the storage is forgotten without the record's destructor, and the error propagates; on success the storage becomes the record and the helper owns nothing; no field is destroyed twice or read uninitialized.
- **Cost.** A record adds build time, most with a record type per route; acceptable at the 50 routes measured, unmeasured for hundreds.
- **Disjointness.** A record that is also a `FromRouteValue`, `FromBody` or `FromBytes` is rejected wherever it appears (M3-054's way). Bare values (zero to two, `Param` opt-in) are unchanged.

**Rejected.**
- Slot arity 4 (40 overloads to 50): every method name hits Mojo 1.1.0's ten-note cap, losing a candidate note, the mismatched-type note and, stateful, the `where` clause; it reaches only three values beside a body and four alone, still bound by position, at ten overloads per further value.
- `def(V, V, V)` only: `PUT` and `PATCH` with a body and `GET` with `Headers` stay unreachable (M3-022's B).
- `Param` fields: the field name already names the placeholder. Fields bound by name in any order: a second binding rule where a compile error suffices (M3-050).
- A `Defaultable` record filled through `field_ref`: without field defaults every record needs placeholder values. `from_route_values(values)` (M3-022's E): names at run time. A tuple (F): no names.
- Requiring a record or `Param` for two values: breaks every bare two-value handler (M3-050). Deferral: the routes stay unreachable.

**Revisit when:**
- Mojo reflects function parameter names: bare values could be checked or bound by name;
- Mojo gains a reflective constructor, field defaults, derived initializers or a way to tell a user-written `__init__`: build through them, or refuse such records, and drop or narrow the unsafe helper;
- a record needs a field that is not a route value (a header field, the state): a carrier decided against M3-052;
- variadic handler types build (`state_fail/variadic_handler_type.mojo`), the note cap changes, or applications find a struct per path a burden: weigh slot arity 4 again.

**Next production slice (M3-062).**
- `RouteValues` in `route_value.mojo`, exported, its docstring giving the contract first. `_registration_rules.mojo`: record and ambiguous-record kinds; the record's rules (a field, each field's kind, the count, distinct placeholders, the names, `Optional` only at a query position, the position), in `_rule` before the family rules, which then see one value on one placeholder; one message each, built as `_misnamed_message` is. `app.mojo`: `_slot`'s record branch, the width function, optional keys per field in `_route`. `_handler_storage.mojo`: the helper, its invariant as its docstring; `check_unsafe.sh` admits importing it, nothing else.
- `tests/test_route_records.mojo` through `TestClient`: DX's example; path and query fields, an `Optional` absent and present; a generic record; one-byte, `Optional[Int]` and `String` fields (padding); `{org-id}`; each 400; an ownership oracle with counted field types (a failure at each field: later fields and the body unconverted, each built field destroyed once, no record destructor; success: each destroyed once); an aborting `__init__`, never called; `Headers` or a body (`Json[T]` too) after a record; bodyless and stateful forms; one and two fields.
- `tests/route_records_api_fail`: each message, stateless and stateful, on both families; the unaccepted shapes; a record in `Param` or `WithHeaders`. Existing tests and fixtures unchanged.
- Loopback: DX's `GET` and `PATCH` over HTTP/1.1 and h2c.
- Verification (`docs/DEVELOPMENT.md` section 3): the base-wide diagnostic comparison, since `_rule` gains reflection; a local `SANITIZE=address ./scripts/test.sh` running the oracle with a heap-allocated `String` field before a failing one.
- Docs: `docs/DX.md` (a records section, the registration rules), `docs/ARCHITECTURE.md` (registration, arity budget, unsafe confinement, revisit index), `docs/SPEC.md`.
- Not in the slice: fields in any order, fields that are not route values, defaults in the literal.
