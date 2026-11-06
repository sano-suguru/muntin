# Registration structure amendment: generic forwarding (M3-015)

> **Current.** Now described in [routing reference, "Typed function values and generic forwarding"](../../reference/routing.md#typed-function-values-and-generic-forwarding) and [ARCHITECTURE, "Registration surface"](../../ARCHITECTURE.md#registration-surface).
> Changed in part since:
> - [M3-096](m3-096-bare-json-bodies-and-results-decision.md) (not built yet, M3-097): the result clause gains `conforms_to(R, JsonFields) or conforms_to(R, Iterable)`, so "the whole clause" is its five branches; a helper copying the three-branch clause no longer builds.

Status: **decision amendment** to "Registration structure decision (M3-014)", made in M3-015 after the slice was implemented. M3-014 decided three edges of the accepted set. The slice accepts more than that, and M3-014's revisit condition "M3-015 cannot keep ... the accepted set beyond the three recorded edges: re-decide before merging it" fired. This record is that re-decision. M3-014's three edges stand as written: edge 2 is still the typed `-> StaticString` function value and helper parameter.

**Found:** a helper that forwards a handler to `get` or `post` can now be generic in two ways that the per-shape overloads did not accept:
- over the handler's result, with its own `where` clause proving the registration's;
- over a request parameter, with the slot's kind decided when the helper is instantiated.

M3-014 measured the typed `StaticString` value and helper (edge 2) and the typed `def(var Int)` spelling, but no helper generic over these types. External review of PR #44 flagged that recording this under edge 2 widened M3-014's meaning without a decision.

**Edge 4, generic forwarding (accepted).** An explicitly typed function value or helper parameter whose result or request-parameter types are generic rather than the concrete types the per-shape overloads required registers when the rules hold for the instantiated types and the compiler can prove the registration's `where` clause from the helper's own constraints at the forwarding call. That clause is not checked against the instantiated type alone: a helper whose generic result has no `where`, or a partial disjunction of the clause's branches (measured: `String or StaticString`, `String or conforms_to(R, ToResponse)`, `StaticString or conforms_to(R, ToResponse)`, `conforms_to(R, ToResponse) or String`), is rejected at the forwarding call with `invalid call to 'get': lacking evidence to prove correctness`, even when instantiated with an accepted type. One branch (`R == String`, `R == StaticString`, `conforms_to(R, ToResponse)`) or the whole clause, also with its branches reordered, proves it. Measured with Mojo 1.1.0 (8189361e) against `main` (the merged M3-014, per-shape overloads) and the slice, each form forwarding to `App.get` or `App.post`:

| Form (helper parameter) | `main` | slice | Edge |
|---|---|---|---|
| `h: def() thin raises Never -> R`, `where R == String` | `no matching method` | registers | 4 |
| `h: def() thin raises Never -> R`, `where R == StaticString` | `no matching method` | registers | 4 |
| `h: def(var A) thin raises Never -> String`, `get` `/x/{id}`, `A = Int` (owned or borrowed handler) | `no matching method` | registers | 4 |
| `h: def(State[S], var A) thin raises Never -> String`, stateful `get` | `no matching method` | registers | 4 |
| `h: def(var A, var B) thin raises Never -> String`, `post` `/x/{id}`, `Int` then a body | `no matching method` | registers | 4 |
| `h: def(var A) thin raises Never -> Response`, `A = Request`, on `get` | `no matching method` | registers (raw) | 4 |
| `h: def(var A) thin raises Never -> Response`, `A = Request`, on `post` | `constraint failed: Request is the whole request, not a body; ...` | registers (raw) | 4 |
| `h: def(State[S], var A, var B) thin raises Never -> String`, stateful `post`, `Int` then a body | `no matching method` | registers | 4 |
| `h: def(State[S], var A) thin raises Never -> Response`, `A = Request`, stateful raw on `get` | `no matching method` | registers (raw) | 4 |
| the same on `post` | `constraint failed: Request is the whole request, not a body; a stateful raw handler ...` | registers (raw) | 4 |
| `h: def(var Note) thin raises Never -> R`, `where R == String`, on `post` | `no matching method` | registers | 4 |
| `h: def(var A) thin raises Never -> R`, `where R == String`, `get` `/x/{id}` | `no matching method` | registers | 4 |
| `h: def() thin raises Never -> R`, `where (R == String or R == StaticString or conforms_to(R, ToResponse))` (the registration's clause; reordered branches register too) | `no matching method` | registers | 4 |
| `h: def() thin raises Never -> R`, no `where` | `no matching method` | `invalid call to 'get': lacking evidence to prove correctness` | none (rejected on both) |
| `h: def() thin raises Never -> R`, `where (R == String or R == StaticString)`, given a `StaticString` handler | `no matching method` | `invalid call to 'get': lacking evidence to prove correctness` | none (rejected on both) |
| `h: def() thin raises Never -> R`, `where conforms_to(R, ToResponse)` | registers | registers | none |
| `[R: ToResponse] h: def() thin raises Never -> R` | registers | registers | none |
| typed `def() thin raises Never -> Response` value | registers | registers | none |
| `h: def(var A) thin raises Never -> String` on `post`, a body (unbounded `A`) | registers | registers | none |
| `[B: FromBody] h: def(var B) thin raises Never -> String` on `post` | registers | registers | none |
| typed `-> StaticString` value; helper `h: def() thin raises E -> StaticString` | `TODO` conversion error | registers | 2 (M3-014) |

The first rows come from the slice's own probes; the stateful post, stateful raw, generic-`R`-on-`post`, slot-and-result, verbatim-clause, no-`where` and disjunction rows were found by the fresh-context review of this amendment and re-measured. The table lists what was probed, not every possible form; edge 4 is the class above. Each form that registers answers as the plain handler would: same status, body, request steps and rules. The rules still reject what they rejected for plain handlers. For example, a generic `A` that becomes `Float64` is `constraint failed: a get handler's parameter ...`.

**Decision:** edge 4 is accepted, and C4r is kept. It follows from the selected structure: the overloads take generic slots and a generic result, so generic code that instantiates them with accepted types reaches them as a plain handler does. Alternatives weighed:
- not merging (D0), keeping the per-shape overloads: this undoes M3-014's decision, which needs a new decision, and edge 4 adds no request behavior or unsoundness that a plain handler does not already have;
- narrowing edge 4 inside C4r: the overloads see only the instantiated types, and no other way to tell a helper's forwarding from a direct registration was found. None was measured, so this is a judgment and not a proven impossibility.

Nothing that registered on `main` stops registering because of edge 4; two forms rejected on both trees change their message (the `lacking evidence` rows). The M2 completion contract is amended for four edges (`docs/SPEC.md`).

**Evidence:** `tests/test_registration.mojo` pins each `main`-differing row, plus the conformance branch as a control: `test_generic_result_helper_forwards_a_text_value`, `test_generic_result_helpers_forward_each_where_branch`, `test_generic_slot_helpers_forward` and `test_more_generic_forwarding_forms` (which also registers the whole clause with its branches reordered). `tests/registration_api_fail/generic_result_disjunction_lacks_evidence.mojo` and `generic_result_without_where_lacks_evidence.mojo` pin the failing side of the boundary, a partial disjunction and no `where` (each `no matching method` built against `main`). The probes for every row above were built against both trees (scratch, not retained).

**Revisit when:** a toolchain change lets an overload see how a caller spelled a type (reconsider whether edge 4 should stay open), or a later item adds a slot kind (generic forwarding then reaches it too, and that item states it; M3-016 states it for `Headers`).
