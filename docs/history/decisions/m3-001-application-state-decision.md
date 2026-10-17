# Application state decision (M3-001)

> **Current.** Now described in [state reference](../../reference/state.md#application-state), [state reference, "Rules"](../../reference/state.md#rules) and [ARCHITECTURE, "Storage and ownership"](../../ARCHITECTURE.md#storage-and-ownership).
> Changed in part since:
> - [M3-004](m3-004-state-storage-decision.md): the ArcPointer representation (and the M3-003 slice built on it) was replaced by a sealed `_Shared[S]`; public API frozen.
> - [M3-014](m3-014-registration-structure-decision.md): the ten stateful overloads became the stateful generic-arity family with a fixed leading State[S].
> - [M3-074](m3-074-state-borrowing-decision.md): State refuses at compile time an S that may borrow.
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

Status: **decision** (M3-001; production is unchanged in it). This section decides how a handler reaches long-lived application data (a repository, a connection, configuration). Muntin must still tell route values, the body and framework-injected state apart at compile time, without parameter names, runtime type identity or backend objects, and without changing the M2 contract.

**Selected: A1, handler-argument injection, with the state bound at registration.** The handler declares a Muntin-owned `State[S]` as its first parameter. The registration passes the state as its second argument:

```mojo
def get_user(users: State[Users], id: Int) raises NotFound -> User:
    return users[].get(id)

var users = State(Users(names^))
app.get["/users/{id}"](get_user, users)       # (handler, state)
app.get["/hello"](hello)                      # every M2 call: unchanged, one argument
```

Neither pure form of the candidates survives the compiler. Pure A (the handler declares `State[S]` and the registration is today's one-argument call) is ambiguous on `post` and has no static source for the value. Pure B (the `App` owns the state) needs `App[S]` or a runtime type check. Binding the state at the registration call keeps A's handler-side declaration and answers B's ownership question without either cost.

**Registration surface: A1, not the scoped registrar A2.** Two surfaces for that binding were measured:
- A1 (selected) adds the stateful overloads to `App` itself: `app.get[route](handler, state)`.
- A2 puts them on a separate registrar type: `var api = app.with_state(users); api.get[route](handler)`. `App` gains only `with_state`, and the registrar holds a `Pointer[App, mut origin]` and a handle (`tests/scoped_state_spike.mojo`).

Both separate injected state cleanly and share everything else in this section. A2 is better on DX:
- `App`'s overloads and every M2 diagnostic stay unchanged: 65 of 65 against A1's 16 changed, 12 of which lose detail notes (table below).
- The state is stated once per registrar instead of once per route.

A2 is rejected on Mojo 1.1.0 because mutation through its stored `Pointer` is invisible to the compiler's interior-reference invalidation.
- A1 registrations are `mut self` calls on `App`. A reference into `App._routes` taken before one is rejected (`scoped_direct_get_invalidates_interior_reference.mojo`: `use of invalidated interior reference`).
- The same write through an A2 registrar that was live before the reference was taken compiles, and after the route list reallocates, the old reference reads freed memory. `tests/state_known_gaps/registrar_blind_mutation.mojo` retains this: `check.sh` builds it and never runs it. The registrar must exist first, because `with_state` is itself a `mut self` call that invalidates an earlier reference.
- A2 would therefore make Muntin's own public API a mutation path the borrow checker does not see. Its safety would rest on a project invariant ("`App`'s public API returns no reference into `App`") instead of on the compiler. With no private fields on 1.1.0, `_routes` is reachable by name even today.
- The registrar would also add a mutable origin-escape hazard: constructed with `MutAnyOrigin`, it can write to a freed `App`. `TestClient[ImmutAnyOrigin]` can already read from one; that existing read-side hole is no reason to add a write-side one.

A1's costs are all DX: longer diagnostics for failing M2 calls, and the state repeated per route. Diagnostics can be improved and sugar added later. A blind mutation path in the public architecture is hard to remove. A2 is a sound idea that is early for Mojo 1.1.0 (revisit conditions below).

**The static rule.**

- *Injected:* a registration with two arguments, `(handler, state: State[S])`. The handler's first parameter is `State[S]`, and `S` is inferred from both arguments, so they must agree (`state_fail/mismatched_state_type.mojo`: `value passed to 'state' cannot be converted from 'State[Cache]' to 'State[Db]'`). After it comes exactly one M2 shape, bound by M2-005 unchanged: route values in the literal's order, then the body.
- *Route value:* `Int` in a route-value position, as in M2. *Body:* the last parameter on `post`, `B: FromBody`, as in M2. *Raw:* `def(State[S], var Request) -> Response`, the M2-015 shape with the state first.
- *Separation from M2:* every M2 call passes one argument, and Mojo filters candidates by argument count before ranking. The stateful family never competes with an M2 overload. A stateful handler registered without its state matches no `get` overload (`get_state_without_argument.mojo`: the stateful candidates' note `missing required argument: 'state'`). On `post` it reaches the generic body overload with `B = State[...]` and fails there. A stateless handler given a state also fails (`state_for_stateless_handler.mojo`), so the state is never silently ignored.
- *Inside the family:* only `post` needs ranking. A stateful raw handler also satisfies the stateful `ToResponse` body overload (`B = Request`, `R = Response`). M2-014's shorter-list rule selects the raw overload: `[S, E, path]`, 3 parameters, against `[S, B, E, R, path]`, 5. The `String` body overload is not viable for a `Response` result. Mutation: two defaulted parameters on the raw overload make the lists equal, and the call becomes `ambiguous call to 'post'`. The two `get` overloads with one parameter after the state, `def(State[S], Int)` and `def(State[S], var Request)`, do not overlap.
- *Disjointness kept:* `State` is a Muntin type in a fixed position. It is not `Int`, it does not conform to `FromBody`, and the stateful body overloads reject a second `State` in the body slot by its private marker trait (`two_states.mojo`: `a handler takes at most one State, as its first parameter`). The application's `S` may be any type, `Int` included: the wrapper is what marks the parameter, not `S`. The placeholder-count checks are unchanged: the state is not a route value (`route_count_with_state.mojo` gets `def()`'s message).
- *Position:* state first is a design rule, not a compiler constraint. A state-last family (`def(Int, var B, State[S])`, DX section 8's old sketch) compiles and selects correctly in a scratch probe. It would make the body the second-to-last parameter on `post`, which restates M2-005's "the remaining last parameter is the body". State first leaves that sentence literal and gives one reading order: injected, route values, body. `state_last.mojo` and `state_after_body.mojo` pin that such handlers do not register.

**Shapes measured** (spike: `StateApp` = production's ten overloads with signatures and asserts copied, the four body overloads gaining the `State` guard, plus ten stateful ones declared before them, all stored in production `_Erased`):

| Method | Stateful shape | Results | Errors |
|---|---|---|---|
| `get` | `def(State[S])`, `def(State[S], Int)` | `String`-compatible, `R: ToResponse` | `thin raises E`, inferred, as M2-011 |
| `post` | `def(State[S], var B)`, `def(State[S], Int, var B)` | same | same |
| `get`, `post` | raw `def(State[S], var Request)` | `Response` | same |

Every request rule is M2's, decided in the same places: 404 without a match; 400 for an invalid route value, a missing, duplicated or invalid query value, or a `from_body` raise, all before the handler (`Users.calls` stays 0); `ToErrorResponse` or the fixed 500 for a raise (`NotFound` 404, bare `raises` 500 without its text); first registration wins. Raw stateful handlers receive the whole `Request` with no pre-handler 400.

**Overload cost: one factor of two, accepted.** The full family is 10 overloads, mirroring the 10 M2 ones: 5 shapes × 2 result policies, with the raw shapes `Response` only. This is the "one overload per permutation" red flag along exactly one axis. The judgment:

- The state axis is binary: with or without. `S` is generic, so more state types add no overloads. `E` is inferred, so errors add none.
- Mojo 1.1.0 offers two ways around the factor, and the compiler closes both. No variadic function types: `variadic_handler_type.mojo`, `expected a type, not a value`. No storable closures: `closure_handler_storage.mojo`, where a function generic over a closure trait is itself `capturing` and does not convert to `_Call[F]`.
- Rule that bounds it: a handler has **one injected slot, the first parameter, and it holds one `State`**. A later injected kind (request context, typed headers) either goes through `S` or `Request`, or needs its own decision. Any new kind that adds a slot doubles the overload count again.
- The factor also applies forward. Every later M2-style addition (`put`/`patch`/`delete`, non-`Int` route values, more arities) costs two overloads per result policy if it gets a stateful twin. Each such decision states whether it does.

**M2-005 rejected a registration argument before; why that does not carry over.** M2-005 candidate 2, a decoder passed at registration, was rejected for "a second argument on every body route and one decoder per position". M2-007 likewise rejected a converter at registration because it restated what the return type already says. The decoder and the converter restated something a type can carry statically, its conversion, and a trait carries it. State is a runtime value, and on Mojo 1.1.0 nothing else can carry it to a thin handler: no globals (`module_level_state.mojo`, `global variables are not supported`), no captures, and no generic `App` without infecting every backend (B1 below). The second argument appears only on the routes that take state, not on every route of a shape. The registration is the one place where the handler's type and the value meet statically. The repeated argument is the cost of that. A2 states it once per registrar, but at the safety cost above.

**Ownership and lifetime.**

- `State[S]` holds an `ArcPointer[S]` (std, reference counted with atomic counts; no unsafe operation). Superseded by M3-004 ("State storage decision (M3-004)"): through a second handle, `ArcPointer` lets code free memory a `state[]` reference points into, so production stores the value in a sealed box in the storage module; the public API below is unchanged. `State(value)` moves the value in. The application keeps its handle. `app.get[...](h, users)` borrows `users` and moves a copy of the handle into the route's `_Erased` box, together with the handler, as one private `_Bound[H, S]` value. The value lives until the last handle goes. Pinned in the spike: `Tracked` is dropped exactly once, after the application dropped its handle and then the moved `App`.
- Per request: the stateful adapter borrows the boxed `_Bound` (`_Erased.invoke` already borrows its value) and passes `bound.state` by borrow. No copy, no reference-count change, no allocation. In the spike, the count is the same inside a handler as between requests (4, for 3 routes and the application's handle). The mutation that copies the handle per request turns it red.
- `App` moves: the value is on the heap, so moving `App` (`var moved = app^`, twice in the spike) moves only the routes' handles. `TestClient(app)` borrows the `App` immutably, and `App.handle(self)` is read-only. Scratch copy: `TestClient` serves a stateful production `App` repeatedly, also after a move, while the application still reads its own handle.
- The compiler tracks every registration: each is a `mut self` call on `App`, so a reference into `App` taken before it is invalidated (`scoped_direct_get_invalidates_interior_reference.mojo`). No project invariant about references into `App` is needed (contrast A2).
- Read-only: `state[]` is `def __getitem__(self) -> ref[self._shared] S`. The receiver is a borrowed `self`, so the reference is immutable through every handle: borrowed, `mut` or owned (`mutate_through_state.mojo`, `expression must be mutable for in-place operator destination`). That line carries the guarantee; the mutation `ref self` makes the fixture compile. `ArcPointer[S][]` alone is mutable through a borrowed pointer (scratch probe), so `State` must not expose its pointer as API. Mojo 1.1.0 has no private fields, so `state._shared[].n += 1` compiles and mutates the shared value (review probe). The guarantee is "read-only through `state[]`", and `_shared` is an internal by name only. This is weaker than `_Erased`'s handle, which needs `unsafe_ptr()`. Read-only is shallow: a type `S` with interior mutability (the spike's `Users.calls`, its own `ArcPointer[Int]`) changes under its own rules, and Muntin does not synchronize it.
- Reference lifetime (M3-003 review): with the spike's `ArcPointer[S]`, a `ref` from `state[]` is not invalidated when its handle is reassigned, and then reads a dropped value. `ArcPointer.__getitem__` returns a reference with the handle's own origin (its source at the 1.1.0 tag has a FIXME saying this is not the right model), while `OwnedPointer[]` returns one the compiler tracks as interior. A first fix, `ArcPointer[OwnedPointer[S]]`, made reassignment a compile error but left a second handle able to replace the shared value. M3-004 ("State storage decision (M3-004)") decided the production representation: a sealed `_Shared[S]` that keeps the interior origin (`tests/state_get_fail/ref_after_*`) and closes the alias paths.
- Concurrency: today `App.handle` is never called concurrently. Flare's multi-worker `serve` requires a `Copyable` handler (each worker gets `H.copy()`), and `MuntinHandler` holds a move-only `App`. A backend that calls `handle` concurrently, or a copyable `App`, would make interior mutability in `S` a data-race question (revisit conditions).
- Several values: one `State` per handler. Several values are fields of one `S`. Different routes may bind different `S` (`State[Users]` and `State[Greeting]` in one app), and several routes may share one value (one count, both routes' calls visible through the application's handle). There is no registry, key or lookup.

**Effect on existing machinery.** `App` stays non-generic. `App.handle(Request) -> Response`, `_Route`, `_Erased`, `_Call[F] = def(F, List[String]) raises thin -> Response` and the unsafe surface are unchanged: `_Bound[H, S]` is one more `F`, and the stateful adapters are `_Call[_Bound[H, S]]`. `check_unsafe.sh` passes unchanged: `ArcPointer` is not an unsafe API. The storage module still names neither request data nor state. `Request`, `Response`, `TestClient`, the Flare adapter and the seam are unchanged.

**M2 stays closed.** No M2 public signature, binding rule or 400/404/500 boundary changes. Two scratch copies of the repository, not retained, each with the full stateful family on production: A1 (`src/muntin/state.mojo` with `State`, ten overloads, `_Bound` and five adapters in `app.mojo`, the `State` guard in the four body overloads) and A2 (the same with `with_state` and a registrar instead of the ten `App` overloads). In both, `./scripts/check.sh`, `./scripts/test.sh` and `./scripts/check_flare.sh` exit 0, with every existing suite count, fixture and expected text unchanged, plus one scratch `TestClient` test each. Diagnostics, compared in full for the 65 fixtures in `compile_fail`, `storage_fail` and `body_fail` that register on production `App` (normalized for paths and line numbers; `raw_fail` builds against the M2-014 spike, and five `storage_fail` fixtures never register):

| | identical | gain notes | of those, trailing detail notes omitted |
|---|---|---|---|
| A1, overloads on `App` (selected) | 49 | 16 (five `missing required argument: 'state'` each, after every M2 candidate's note) | 12 (Mojo's cap of ten notes per diagnostic; one to five notes, such as `result type of the first type is 'String' but the second type is 'R'`) |
| A2, registrar (rejected) | 65 | 0 | 0 |

Under A1, no candidate note, constraint message or error line is lost, and every expected text still matches. What gets shorter is the explanation a user reads for a failing M2 call. `scoped_app_keeps_detail_notes.mojo` pins A2's side of one such call. The `get` slice below adds four notes, to `get` calls only.

The body-overload guard, when it ships with the stateful `post` slice, changes only the message of calls that already fail, as M2-015's `Request` guard did. (Shipped in M3-006: "Stateful POST in production (M3-006)".)

**Candidates** (Mojo 1.1.0 (8189361e)):

| Candidate | Result | Verdict |
|---|---|---|
| A1. `State[S]` handler parameter, bound at registration `(handler, state)` | every shape, result, error kind and raw form; separated from M2 by argument count; every registration a `mut self` call the compiler tracks; costs: 16 failing M2 diagnostics gain notes (12 lose detail notes) and the state is repeated per route; ownership by a shared read-only handle; `_Erased`/`_Call`/unsafe/backends unchanged; M2 suites and fixtures unchanged on a scratch copy | **chosen** |
| A2. `State[S]` handler parameter, bound by a scoped registrar `app.with_state(state).get[route](h)` | every shape, result, error kind and raw form; `App`'s overloads and all 65 M2 diagnostics unchanged; the state stated once per registrar; moving the `App` while a registrar is used is rejected. But writes through the registrar's stored `Pointer` escape interior-reference invalidation (a stale reference into `App._routes` reads freed memory; retained build-only probe `state_known_gaps/registrar_blind_mutation.mojo`), safety would rest on the invariant that `App`'s public API returns no reference into `App`, and a `MutAnyOrigin` registrar can write to a freed `App` | rejected on Mojo 1.1.0 (kept as evidence; revisit condition) |
| A0. `State[S]` handler parameter through today's one-argument registration | `ambiguous call to 'post'` against the generic body overload, equal lists (`one_argument_injection_is_ambiguous.mojo`): a concrete wrapper does not outrank a generic `B`. Even with a ranking fix (bounding `B: FromBody` in the signature, M2-014 candidate 3), the value still needs a static source, which leads to B1 or B2 | rejected |
| B1. `App[S]` owning the state (with a default `S`) | a backend storing `App` by name no longer names a concrete type (`generic_app_backend_field.mojo`: `'App[_]' is not concrete`); binding the default (`App[]`) serves only stateless apps (`generic_app_backend_default_only.mojo`: `cannot be converted from 'App[Db]' to 'App'`). `MuntinHandler`, `TestClient`'s `Pointer[App, origin]` and every `App` in application code become generic over `S`: the coupling M2-012 rejected for `App[on_error=m]` | rejected |
| B2. non-generic `App` storing one erased state value (`app.state(v)`), handlers asking for `State[S]` | nothing links the stored type to a handler's `S` at compile time, so dispatch must check it at run time. Mojo 1.1.0's only runtime type identity is `reflect[T].name()`, a module-qualified `String` (`test_runtime_type_identity_is_only_a_name_string`). The check would be a string key and the recovery an unsafe cast outside `_handler_storage.mojo` | rejected (string type keys, downcast, unsafe expansion) |
| C. no state feature | no application pattern exists: module-level variables do not compile, thin handlers cannot capture, raw handlers receive only the `Request`. The only process-wide mutable store a thin function reaches is the environment, which Muntin's own tests use as call counters (strings, global, not a state model) | rejected, because A meets the bar |
| D. capturing closures as handlers (state by capture) | a closure passes through a parameter bounded by its function trait, but the generic trampoline becomes `capturing` and does not convert to `_Call[F]` (`closure_handler_storage.mojo`). It would change `_Call`/`_Erased` and every M2 registration signature (thin function types): an M2 reopen | rejected on 1.1.0; revisit condition |
| E. one generic registration over all arities (variadic function type) | `expected a type, not a value` (`variadic_handler_type.mojo`) | not expressible |
| state-last family | compiles in a scratch probe | rejected: the body stops being last (M2-005) |

**Name.** `State` collides with nothing in the Mojo 1.1.0 prelude (`use of unknown declaration 'State'`) or in Muntin. Flare 0.11 has its own `flare.http.State[T]`, a registration-time field of Flare's struct handlers that is copied per request and requires `Copyable & Defaultable`. Application code never imports Flare, and the adapter imports names explicitly, so the names do not clash. Muntin's type is independent of Flare's.

**Evidence.**
- `tests/state_spike.mojo` (library side): `State`, `_InjectedState`, `_Bound`, five stateful adapters, and `StateApp` with production's ten overloads (signatures and asserts copied; the four body overloads gain the `State` guard) plus the ten stateful ones. It imports production `_Erased`, adapters, route checks, matching, query gathering and `_handler_error`.
- `tests/scoped_state_spike.mojo` + `tests/test_spike_scoped_state.mojo` (A2, 6 tests): every stateful shape through one registrar; request failures and the error model; a chained temporary registrar between stateless registrations; two state types and a shared value; the registrar's handle released with it; a drop exactly once across two `App` moves.
- `tests/test_spike_state.mojo` (11 tests): every stateful shape and result; request failures with the handler not called; the error model; raw stateful `get`/`post` with borrowed and `var` requests; M2 shapes beside stateful routes in one app; two state types and a shared value; the reference count at registration, inside a request and after `App` is dropped; a drop exactly once across two `App` moves; the application's handle after requests; the runtime type-identity fact.
- `tests/state_lib_only/driver.mojo`: built by `check.sh` without the application modules; registers every stateful shape both ways (A1 and A2) on a state type the libraries have never seen and compares the responses.
- `tests/state_known_gaps/registrar_blind_mutation.mojo`: must build, never run (`check.sh`). It pins the A2 rejection, a registrar write that the interior-reference check misses, beside its rejected direct counterpart in `state_fail`.
- `tests/state_fail` (24): one per rule, one per rejected candidate, and seven for A2: a mismatched state type, a stateless handler on a registrar, a stateful handler on `app.get` and on `app.post`, the `App` moved while a registrar is used, detail notes kept, and a direct registration invalidating an interior reference.
- Mutations (planted, reverted; 12), each red. In A2 (5): a registrar `post` registered as `GET`; the registrar's raw `get` not marked raw (crash); the guard removed; `with_state` on an immutable `self` (build fails); the registrar's raw `post` list made as long as its body list (`ambiguous call`). In A1 (7):
  - route value and body slots swapped;
  - a bad route value calling the handler;
  - the handle copied per request;
  - the stateful raw route not marked raw (crash);
  - `__getitem__(ref self)` (the read-only fixture compiles);
  - the `State` guard removed (the fixture loses its message);
  - the raw `post` list made as long as the body list (`ambiguous call`).

**Fresh-context review (A1).** No material issue. The review probed and confirmed: `-> StaticString`; keyword spellings (`handler=`, `state=`, either order); `S = Int`, `String`, `Request` and nested `State`; a `FromBody` type used as both state and body; `mut`, `ref` and generic state parameters, all rejected; mutation through `state[]` under every assignment form; Flare's `Copyable` requirement for multiple workers; that M2 overloads drop out by argument count (`unexpected argument`); and that the unsafe surface is unchanged.

Minor findings, all applied:
- the diagnostics count is restricted to fixtures that register on `App`;
- the factor of two also applies to future shapes and methods;
- the `_shared` bypass is named, and the summaries say "read-only through `state[]`";
- DX section 8's "both work";
- B1's rejection reason, and M2-007 cited beside M2-005;
- the spike's guarded body overloads;
- note order and the "unsafe" comment rule for the slice.

**A2 and the PR review.** The PR review asked for the scoped registrar to be measured before a registration surface was frozen, because A1's measured diagnostic cost made it a real candidate. The measurement favored A2 on diagnostics, and A2 was briefly selected.

A fresh-context review of A2 then found the interior-reference gap. A second PR review weighed that gap as a safety-model cost, not a documentation issue, and A1 was restored. Minor findings of the A2 review that still apply are recorded: the `AnyOrigin` escape; `_ = app^` with a live registrar is lifetime-extended, not a destroy point; and an immutable borrow can coexist with a live registrar.

**Revisit when:**
- `variadic_handler_type.mojo` or `closure_handler_storage.mojo` compiles: a closure or variadic form could replace the stateful family. Re-decide before adding more stateful shapes;
- `one_argument_injection_is_ambiguous.mojo` compiles, or the generic-`App` fixtures compile (a defaulted parameter no longer infects a field named `App`): A0 or B1 would need re-measuring;
- `module_level_state.mojo` compiles: candidate C gains an application pattern, though a global still fails "no hidden globals" and testability;
- a backend calls `App.handle` concurrently, or `App` becomes `Copyable` (Flare multi-worker): read-only `State` stays safe, but interior mutability in `S` needs a documented synchronization rule;
- a second injected kind is proposed: it must not add a second slot without its own decision, because the overload count would double again;
- Mojo can express the scoped registrar without a blind mutation path: writes through a stored mutable reference invalidate interior references (`state_known_gaps/registrar_blind_mutation.mojo` then stops building, and `check.sh` fails on it), or a `ref` field or another non-`Pointer` form can hold the borrow. Then re-measure A2 (`scoped_state_spike.mojo`) as the fix for A1's diagnostics and repetition;
- the truncated detail notes of failing M2 calls, or the repeated state argument, are measured as a DX problem before that: improve the diagnostics or add sugar without a stored mutable `Pointer`;
- a toolchain change alters `ArcPointer`'s interface, or the receiver rule that makes `state[]` immutable (`mutate_through_state.mojo` compiles).

**Next production slice (M3-003): stateful `get`.** **Superseded by M3-004. Do not implement the representation below** (`ArcPointer[S]`, `check_unsafe.sh` unchanged): the authoritative rebased slice is "Next production slice (M3-003, PR #26, rebased)" in "State storage decision (M3-004)". The plan is kept as the record of M3-001. M3-003 was implemented from that slice (`docs/SPEC.md`, "M3-003 result"). Details the implementation settled: the production fixtures are `tests/state_get_fail` (mismatched type, state-last, missing state argument, state for a stateless handler, plain value, owned parameter, mutation through a `mut` handle and inside a handler, a reference used after its handle is reassigned or returned from it, and a second handle replacing or mutating the value) and `tests/compile_fail/state_*.mojo` (placeholder counts and malformed routes); the loopback route is `GET /staff/{id}`; DX section 2 needed no change. Of the 70 existing fixtures that build against production, 8 failing `get` calls gain the four stateful candidates' notes, 3 of them losing trailing detail notes; no expected text changes.
- `src/muntin/state.mojo` (new): public `struct State[S: Movable & Deinitable](Copyable, Movable)` with `_shared: ArcPointer[S]`, `__init__(out self, var value: S)` and `__getitem__(self) -> ref[self._shared] S`, exported from `muntin`. No marker trait yet: it is only needed by the `post` guard.
- `src/muntin/app.mojo`: private `_Bound[H, S]`, `_call_state_none[S, E, R, respond]` and `_call_state_int[S, E, R, respond]` (the spike's, error handling and 400s as their M2 twins); four `App.get` overloads `(handler: def(State[S]) thin raises E -> String | R, state: State[S])` and `(def(State[S], Int) ..., state: State[S])`, each with its stateless twin's route asserts and messages, placed after the stateless `get` overloads; the module comment and docstrings.
- Unchanged: `_handler_storage.mojo`, `_Erased`, `_Call`, `_Route`, `App.handle`, `http.mojo`, `body.mojo`, `testing.mojo`, `adapters/flare/muntin_flare.mojo`, `check_unsafe.sh`, and every existing test, fixture and expected text.
- Fixtures: production counterparts of the `get` fixtures in `state_fail` (`mismatched_state_type`, `state_last`, `get_state_without_argument`, `state_for_stateless_handler`, `plain_value_as_state`, `owned_state_parameter`, `mutate_through_state`, `route_count_with_state`).
- Tests (`tests/test_state.mojo`): the spike's `get` cases on production `App` through `TestClient`, plus the reference count, the drop and `App`-move cases. Loopback through Flare adds one stateful `GET /users/{id}`, equal to `TestClient`.
- Docs: DX section 8 becomes a compilable, tested example (registering only `get` routes), and the status lines in sections 2, 19 and "Still targets" are updated.
- Notes: the slice places the stateful overloads after the stateless ones (the spike declares them first), so candidate notes appear in a different order. The fixtures' expected texts are substrings and do not depend on it. Comments in `state.mojo` must not use the word "unsafe": `check_unsafe.sh` matches comments too.
- Known gap until the next slice: a stateful handler on one-argument `post` reports the `FromBody` message. The `State` guard and its marker ship with the stateful `post` overloads, so no message points at an overload that does not exist yet. Closed by M3-006.
- Not in the slice: stateful `post` (body, route value then body), stateful raw handlers, the guard, a scoped registrar (rejected above), middleware, headers.
