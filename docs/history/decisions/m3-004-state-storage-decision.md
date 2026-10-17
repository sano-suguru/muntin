# State storage decision (M3-004)

> **Current.** Now described in [ARCHITECTURE, "Storage and ownership"](../../ARCHITECTURE.md#storage-and-ownership) and [state reference, "Rules"](../../reference/state.md#rules).

Status: **decision** (M3-004; production is unchanged in it). It decides how `State[S]` stores the shared value. The public API decided in M3-001 is frozen: `State(value)`, `.copy()`, `state[]` read-only, a `State[S]` first handler parameter bound by `app.get[route](handler, state)`. Only the representation behind it changes.

**Why it was reopened.** M3-001 put an `ArcPointer[S]` in `State` and called it "safe std, no unsafe code". The PR #26 review of the M3-003 slice showed that this does not hold on Mojo 1.1.0:
- `ArcPointer.__getitem__` returns a mutable reference through any handle, borrowed ones included. Its source at the 1.1.0 tag has a FIXME saying the origin it returns is not the right model.
- Mojo 1.1.0 has no private fields, so `_shared` is reachable by name.
- Together: code holding a second copy frees memory a reference from `state[]` points into, through public std API alone and without writing `unsafe`. With `ArcPointer[S]`, `b._shared[].names.clear()` leaves `ref first = a[].names[0]` dangling (`tests/state_storage_known_gaps/arc_alias_clear.mojo`). With PR #26's `ArcPointer[OwnedPointer[S]]`, `b._shared[] = OwnedPointer(Db(2))` drops the value `ref r = a[]` reads (`arc_alias_swap.mojo`, the review's case).

This is the hazard class A2 was rejected for (M3-001): a stale reference the compiler does not see, reached through Muntin's names and public std API. It is not an M2 reopen: `App.handle`, `_Erased`, `_Call`, binding and 400/404/500 are untouched.

**The guarantee.** The review first asked that no name or safe pointer API reach the payload. Mojo 1.1.0 cannot meet that for any type, Muntin's or the stdlib's. The gate's fresh-context review showed it with primitives that need neither the word `unsafe` nor a stdlib-private field (`tests/toolchain_soundness_gaps`):
- **origin laundering:** `rebind[Pointer[T, MutAnyOrigin]](Pointer(to=x))` makes any borrowed value mutable. Through the public `state[]` alone, a second alias frees what a reference from the first points into, and the same works on a borrowed std `List`;
- **forged allocation:** public `alloc(...).into_thin()` makes an uninitialized `ThinAllocation`, and `swap` puts it in place of an owning field by name. It crashes `State`'s box and production `_Erased` on `main` alike;
- **`memmove`** (deprecated, a warning only): it bit-copies one handle over another;
- **stdlib-private fields** reached by name: `ThinAllocation._ptr`, `List._len`, `OwnedPointer._inner._ptr`, `app._routes._len` (M2-004, re-probed on `main`).

The guarantee M3-004 makes is therefore this: **Muntin must not introduce a Muntin-specific safe-code path that lets one `State` alias replace, mutate, swap, or prematurely destroy the shared payload observed through another alias. Toolchain-wide primitives that can violate the same property for standard-library types and existing Muntin storage (origin rebind, forged allocation or header replacement, `memmove`, stdlib-private fields) are outside this guarantee and are pinned as Mojo 1.1.0 toolchain-wide soundness gaps.** Candidates are compared on the ordinary path that is Muntin's own: an alias, then Muntin's representation, then the payload.

**Selected: A, a sealed shared box in the private storage module.**

```mojo
struct _SharedHeader[S: Movable & Deinitable](Movable):
    var count: Atomic[UInt64]
    var value: OwnedPointer[S]

struct _Shared[S: Movable & Deinitable](Copyable, Movable):
    var _header: ThinAllocation[_SharedHeader[S]]   # the only field
    def owned(self) -> ref[origin_of(self._header.unsafe_ptr()[].value)] OwnedPointer[S]

struct State[S: Movable & Deinitable](Copyable, Movable):   # public API unchanged
    var _shared: _Shared[S]
    def __getitem__(self) -> ref[origin_of(self._shared.owned()[])] S
```

- **Sharing:** the copy constructor increments the count; `__deinit__` decrements it, and the last handle drops the value and frees the header. The count is atomic with `ArcPointer`'s orderings (relaxed increment, release decrement, acquire fence before freeing), so copying a `State` across threads keeps `ArcPointer`'s guarantee.
- **Read-only:** `owned(self)` borrows its receiver, so every reference it yields is immutable, whatever handle it is reached through. That one line carries the guarantee: making it `ref self` lets a second handle assign the value (`alias_owned_assign.mojo` compiles). `State.__getitem__` adds nothing to it, so it no longer needs PR #26's `ImmOrigin(...)` wrapper (the mutation removing that wrapper stays green in A).
- **Lifetime:** the `OwnedPointer` inside the header gives the reference from `state[]` an origin interior to the handle (`a._shared._header.value["value"]`). Using it after the handle is reassigned, directly, through `mut`, or by assigning a new box to `_shared`, is `use of invalidated interior reference`. Using it after a move is `use of uninitialized value`, and returning it as a reference into the handle is `cannot return reference with incompatible origin`. With the value inline in the header instead, those fixtures compile (mutation), so the `OwnedPointer` is load-bearing.
- **Second handles:** pointing `b` at a new box (`b._shared = _Shared(...)` or `b = State(...)`) only drops `b`'s share; a reference from `a` keeps reading its value (`test_repointing_another_handle_keeps_the_value`). Code holding `b` cannot reach the shared value mutably through Muntin's names and public std API:
  - `b._shared[] = ...` is `'_Shared[Db]' is not subscriptable`;
  - `b._shared.owned() = ...` is `expression must be mutable in assignment`;
  - `b._shared.owned()[].names.clear()` is `invalid use of mutating method`;
  - `swap(b._shared.owned(), other)` is `value passed to mutable argument 'lhs' must be mutable`;
  - copying a header over another is `cannot be implicitly copied`, and moving one is `abandoned without being explicitly destroyed`.
- **Outside the guarantee (pinned):** each toolchain-wide primitive above still reaches the payload, `b._shared._header._ptr[].value = OwnedPointer(...)` and the forged-header swap included. Each is a must-build file in `tests/toolchain_soundness_gaps` (built without `--Werror`, because `memmove` warns). Two of them break production `_Erased` on `main` and a std `List` the same way, so none of them is specific to the box.
- **Per request:** unchanged from M3-001. A registration stores one copy of the handle with the handler in `_Erased`, and a request borrows it. In the spike, five calls through production `_Erased` leave the count at 3, and dropping the two boxes brings it back to 1.

**Cost.** Two allocations per `State` when it is built (header, `OwnedPointer`), as with PR #26's representation. Each access goes through two pointers. There is no request-path cost.

**Location and guard.** `_SharedHeader` and `_Shared` go into `src/muntin/_handler_storage.mojo`, which stays the only module allowed unsafe operations. Its docstring's scope widens from handler storage to Muntin's private storage. `scripts/check_unsafe.sh` changes in one rule: other modules may import `_Erased` or `_Shared` from it (`from ._handler_storage import _Erased` stays, and `state.mojo` adds `from ._handler_storage import _Shared`). `state.mojo` names no `OwnedPointer`, `ArcPointer` or unsafe API, so PR #26's one-word exemption for `state.mojo` is removed. Unsafe operations added to the storage module:
- `OwnedPointer.unsafe_take_allocation` + `Allocation.into_thin`: create the header;
- `ThinAllocation.unsafe_ptr`: read the header (count, accessor);
- `Pointer.unsafe_mut_cast` + `unsafe_origin_cast[MutUntrackedOrigin]` + `ThinAllocation(unsafe_owned_ptr=)`: the copy constructor's second owning handle on the same header;
- `ThinAllocation.unsafe_leak` + `OwnedPointer(unsafe_from_raw_pointer=)`: release the last handle.

The invariant the compiler does not check: every `ThinAllocation` of a header is counted exactly once, created only by `_Shared.__init__` (count 1) or its copy constructor (count + 1) and leaked only by `__deinit__` (count - 1), and the header and value are freed only at zero. `_Shared` exposes `owned` and `count` and nothing mutable.

**Candidates** (Mojo 1.1.0 (8189361e)):

| Candidate | Result | Verdict |
|---|---|---|
| A. sealed `_Shared` (`ThinAllocation` header, atomic count, `OwnedPointer[S]`) in the storage module | public API unchanged; every ordinary alias path (replace, mutate, swap, assign through the accessor, header copy or move) rejected at compile time; reference lifetime and read-only compiler-checked; reachable only through the toolchain-wide primitives, as `_Erased` and std types are; two allocations per `State`; one guard rule widened | **chosen** |
| B. `ArcPointer[S]` (M3-001) | a second handle frees memory a `state[]` reference points into through an ordinary path, `_shared[]` (`arc_alias_clear.mojo`); reassigning the last handle leaves a `ref` dangling | rejected |
| B′. `ArcPointer[OwnedPointer[S]]` (PR #26) | reassignment checked, but a second handle replaces the shared `OwnedPointer` (`arc_alias_swap.mojo`, the review's case) | rejected |
| C. scoped access (`state.read[f]()`) or a handler-only opaque handle | not measured: both change M3-001's public API, which A keeps | not pursued |
| D. narrow the contract to "safe through public API" | contradicts the A2 and M2-004 bar | rejected |
| E. wait for the toolchain (`ArcPointer` indirect origins, private fields, a sound `rebind`/`alloc`) | the literal bar fails for every type on 1.1.0, `main`'s included, so waiting would block more than `State`; under the guarantee above, A meets it now | not needed |

**Evidence.**
- `tests/state_storage_spike.mojo` (library side: `_SharedHeader`, `_Shared`, `State`, and a `_Bound`-like box in production `_Erased`) + `tests/test_spike_state_storage.mojo` (5 tests): copies share one value and count; the value is dropped once after the last handle, also after a move; repointing a second handle keeps the first's value; reassigning releases one share; requests borrow the boxed handle.
- `tests/state_storage_lib_only/driver.mojo`: built by `check.sh` without the application module; boxes and shares a state type the library has never seen.
- `tests/state_storage_fail` (11): the alias cases above (subscript replacement, accessor assignment, value mutation, accessor swap), header copy and move, mutation through `state[]`, the reference after reassignment (direct, through `mut`, of the box) and returned from a handle.
- `tests/state_storage_known_gaps` (2, must build): B and B′ as above, each an ordinary alias path.
- `tests/toolchain_soundness_gaps` (5, must build, warnings allowed): `rebind_origin` (through `state[]` and a std `List`), `alloc_forge_state_box`, `alloc_forge_erased` (production `_Erased` on `main`), `memmove_handle`, `std_private_field`.
- Mutations (planted in the spike, reverted; 6), each red: `owned(ref self)` (`alias_owned_assign` and `alias_owned_swap` compile); a mutable subscript on `_Shared`; a copy without the increment (crash); a drop that frees on every handle (crash); the value inline in the header (the three reassignment fixtures compile); the handle copied per call.
- Scratch copy of the M3-003 branch with A applied (not retained): `_Shared` in the storage module, `State` over it, the exemption removed and the import rule widened, plus the two alias fixtures in `tests/state_get_fail`. `./scripts/check.sh`, `./scripts/test.sh` (`test_state` 11/11, every suite unchanged) and `./scripts/check_flare.sh` exit 0, with 14 `state_get_fail` fixtures passing.

**Revisit when:**
- a file in `tests/toolchain_soundness_gaps` stops building: the toolchain improved. Reevaluate whether the sealed box and its unsafe boundary can be simplified, and narrow the guarantee's exclusions;
- `arc_alias_swap.mojo` or `arc_alias_clear.mojo` stops building: `ArcPointer` no longer hands out mutable references through shared handles (its FIXME is resolved). Re-measure B, which needs no unsafe code;
- Mojo gets private fields: `_shared` and `_header` can be sealed by visibility, and the guard rule can narrow again.

**Next production slice (M3-003, PR #26, rebased).** Implemented in M3-003 as listed (`docs/SPEC.md`, "M3-003 result").
- `_handler_storage.mojo` gains `_SharedHeader` and `_Shared` as in the spike, its docstring's scope, unsafe list and downstream paragraph updated to the boundary above (ordinary paths closed; the forged-header replacement of `_Erased._header` named among the toolchain-wide gaps);
- `state.mojo` holds `_Shared[S]`, with `__getitem__(self) -> ref[origin_of(self._shared.owned()[])] S`, and imports `_Shared` instead of `ArcPointer`/`OwnedPointer`;
- `check_unsafe.sh` drops the `state.mojo` exemption and allows importing `_Shared`;
- `tests/state_get_fail` gains `alias_payload_swap` and `alias_value_mutation`, and keeps the `ref_after_*` fixtures;
- tests read the count through `_shared.count()`.

Everything else in PR #26 stands.
