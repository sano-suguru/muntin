# Request context storage decision (M3-065)

> **Current.** Now described in [ARCHITECTURE, "Storage and ownership"](../../ARCHITECTURE.md#storage-and-ownership) and [deferrals, "Request context over a closed type (M3-065)"](../deferrals.md#request-context-over-a-closed-type-m3-065).
> Changed in part since:
> - [M3-074](m3-074-state-borrowing-decision.md): `State` no longer has the gap this record names: it refuses at compile time a value that may borrow (`tests/state_fail/state_origin_*`).

Status: **decision**, a standing constraint (M3-065, pull request #118; `src/muntin` unchanged). The probes are in the pull request.

**Question and what settles it.** [M3-063](m3-063-request-context-decision.md) fixed the context's API (`request.context.set(value^)` for a value of any type, read by a `Context[T]` slot) and left its storage open. Can Mojo 1.1.0 store such a value behind the non-generic `App` and `Request` and never restore it as another type, through a type identity the compiler guarantees, a table fixed at registration, or a shape that needs no identity? Settled by: the standard library at tag `mojo/v1.1.0` searched for a type identity; compile-time type equality probed; a store that erases one type only, so that no identity is involved, run under AddressSanitizer; a context type the application declares, written by middleware, compiled.

**Choice: no storage erases a context value. Its type is a type parameter that the code writing it and the code reading it share statically, so M3-063's open `set(value^)` is withdrawn; the API is decided again for a closed context type.**
- Mojo 1.1.0 has no run-time type identity: reflection gives names, linkage names and fields; `Variant` and `TypeList.contains` compare types at compile time only.
- None of the identities probed tells origins apart: the reflected name prints each as `{}`, the linkage name merges them (`tests/context_known_gaps/reflected_names_collide.mojo`), and generic `==`, which `Variant` indexes by, ignores their identity (`tests/registration_known_gaps/generic_equality_ignores_origin_identity.mojo`). Whether the compiler specializes by origin anywhere else is not established; nothing found documents it.
- Erasure drops a value's origin even if nothing restores the value: a guard on a middleware's local is stored, the checker ends the local, and dropping the store runs the guard's destructor on freed memory (`tests/context_known_gaps/erasure_drops_origin.mojo`, heap-use-after-free). A generic `set[T]` has no way to refuse such a `T`, so no key, however exact, makes open storage sound. Production `State` has the same gap today (`tests/state_known_gaps/state_borrows_dropped_local.mojo`), a memory-safety defect tracked ahead of feature work (issue #122). `check.sh` only builds both files; `scripts/run_origin_gaps.sh` runs them and requires the report.
- A field of a type the application declares keeps the origin: storing a view of a local in an `Optional[View[ImmStaticOrigin]]` field does not compile, and no field may name `AnyOrigin` (`tests/context_fail`). So a closed context type, created and restored only by code instantiated with it (as `_Erased` pairs its functions, `docs/ARCHITECTURE.md`, storage and ownership), needs no identity. That it is sound is a premise, not a result: only a field's check is shown here, and the API decision verifies the whole path. Any guarantee excludes a value built with `AnyOrigin`, which a struct parameter still accepts, as for standard types (`tests/registration_known_gaps/safe_dangling_any_origin_slice.mojo`).

**Rejected.**
- Keying by any identity Mojo 1.1.0 offers (reflected name, linkage name, a specialized function's address, generic `==`): none includes origins, and erasure drops them anyway.
- Admitting only types whose reflected name shows no parameter, or no origin (`{`): reads an undocumented display format.
- A key object: one made by the `App` at run time cannot reach a middleware (a thin function with no captures; module-level variables do not compile), and a module-level `comptime` key has no identity beyond its parameters, so comparing two of them needs the missing type identity.
- A table fixed at registration and keyed by type: the handler's slot is known at registration, but `set` runs in a middleware that nothing links to it except the type, so the table needs the identity this record finds missing.
- Deferring with the open API kept: no Mojo 1.1.0 feature, documented or measured, would make it sound, while a closed type is a candidate whose premise holds in the probe above.

**Revisit when:**
- Mojo documents a run-time type identity that includes origins and a way for generic code to refuse or bound an erased value's origins: measure open storage again;
- `tests/context_known_gaps/erasure_drops_origin.mojo` or `tests/registration_known_gaps/generic_equality_ignores_origin_identity.mojo` stops building, or `scripts/run_origin_gaps.sh` (run when the Mojo version changes) stops seeing the use-after-free: measure open storage again;
- a `tests/context_fail` fixture builds: a context type's fields no longer keep origins, and the closed type loses its premise;
- the API decision's whole-path check fails under AddressSanitizer: decide this record again.

**Next production slice: none.** The rule is in `docs/ARCHITECTURE.md` (storage and ownership). The closed type's API is a decision in `docs/SPEC.md`, "Remaining candidates", whose candidates and conditions are in `docs/history/deferrals.md`; [M3-064](m3-063-request-context-decision.md), the owning `App.handle`, does not depend on it.
