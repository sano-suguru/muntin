"""Muntin's private storage: the handler box `_Erased`, the shared state
box `_Shared`, and `_build_record`, which builds a route-value record field
by field.

Not part of Muntin's public API; nothing here is exported from `muntin`.
This is the only module in `src/muntin` allowed to use unsafe pointer or
ownership operations (`scripts/check_unsafe.sh` fails otherwise). Decision
and evidence: docs/history/architecture-decisions.md, "Handler storage decision (M2)" and its
"Production implementation (M2-004)" for `_Erased`, "State storage decision
(M3-004)" for `_Shared`, "Route-value records decision (M3-061)" for
`_build_record`.

A handler value of type `F` is moved into an `OwnedPointer[F]`, and the
allocation is then held as an opaque pointer. Only the pointer is erased;
the bytes of `F` are never reinterpreted, so nothing depends on how Mojo
represents a function value. Ownership returns to an `OwnedPointer[F]`
through its documented `unsafe_from_opaque_pointer` constructor, whose
contract is this round trip.

The opaque pointer and the two functions that may restore it as `F` are
kept together in one heap `_Header`, and `_Erased`'s only field is the
move-only `ThinAllocation[_Header]` that owns it. Mojo 1.1.0 has no private
fields, so code outside this module can name `_Erased`'s field; it still
cannot copy, overwrite or move the handle out (compile errors, pinned by
`tests/storage_fail/downstream_*.mojo`), and reaching the header's fields
takes `unsafe_ptr()` or the stdlib's own private `ThinAllocation._ptr`.
Swapping two handles keeps each pairing intact. The helpers that touch
the erased pointer are named `_unsafe_*`, so no caller can reach them
without writing `unsafe`. These close the ordinary paths; Mojo-wide escape
hatches are outside that boundary: a header forged with the public `alloc`
and swapped in by field name, `rebind`, `memmove`, stdlib-private fields
(`tests/toolchain_soundness_gaps`).

`_Shared[S]` is the reference-counted handle behind the public `State[S]`.
Its only field is a move-only `ThinAllocation` of a `_SharedHeader`: an
atomic count and an `OwnedPointer[S]` holding the value. Copying a
`_Shared` increments the count; dropping the last one drops the value and
frees the header. Its accessor `owned(self)` borrows its receiver, so every
reference it yields is immutable, and the `OwnedPointer` makes a reference
to the value interior to the handle it was reached through. On ordinary
paths, code holding another handle cannot replace, mutate, swap, copy or
move the value, nor copy or move a header over another (swapping two real
handles' headers only re-pairs them, and the compiler invalidates the
references that depended on them); the same escape hatches as for
`_Erased` remain outside that boundary.

Unsafe operations, all in this module:
- `OwnedPointer.unsafe_take_allocation` + `Allocation.unsafe_leak`: the
  value's allocation stops being owned by an `OwnedPointer[F]` (`_unsafe_erase`);
- `Pointer.unsafe_bitcast`: `F` to `NoneType` when erasing, `NoneType` to
  `F` when invoking (`_unsafe_erase`, `_unsafe_invoke_box`);
- `[]` on the untracked `Pointer[F, MutUntrackedOrigin]` (`_unsafe_invoke_box`);
- `OwnedPointer(unsafe_from_opaque_pointer=)`: ownership restored as `F`
  and released (`_unsafe_drop_box`);
- `OwnedPointer.unsafe_take_allocation` + `Allocation.into_thin`,
  `ThinAllocation.unsafe_ptr`, `ThinAllocation.unsafe_leak` +
  `OwnedPointer(unsafe_from_raw_pointer=)`: the header's allocation is made,
  read, and released (`_Erased`, `_Shared`);
- `Pointer.unsafe_mut_cast` + `Pointer.unsafe_origin_cast[MutUntrackedOrigin]`
  + `ThinAllocation(unsafe_owned_ptr=)`: a second owning handle on the same
  shared header (`_Shared`'s copy constructor);
- `MaybeUninit.unsafe_ptr`, `unsafe_bitcast` and `unsafe_offset` to a
  field's reflected offset, `unsafe_write`, `unsafe_take_pointee`,
  `MaybeUninit.unsafe_forget` and `unsafe_assume_init`: a record's fields
  written in place, destroyed on failure, and the storage forgotten or
  taken as the record (`_build_record`, whose docstring states its own
  invariant).

Invariant, which the compiler does not check (`MutUntrackedOrigin` is an
origin the lifetime checker does not track):
- `_value` points to one live `F` allocated by `OwnedPointer[F]`, and its
  header is owned by exactly one `_Erased`;
- a header is written only by `_Erased.__init__`, which instantiates
  `_unsafe_invoke_box` and `_unsafe_drop_box` with the same `F` it allocated, so the
  pointer is only ever restored as that `F`;
- `_Erased` exposes only `invoke`; other modules in `src/muntin` import
  only `_Erased`, `_Shared` and `_build_record` (`check_unsafe.sh`);
- `_Erased` is `Movable` and not `Copyable`: a move transfers the handle
  without running `__deinit__` on the source, `__deinit__` frees the value
  and then the header exactly once, and `invoke` borrows the owning
  `_Erased`, so both allocations outlive every call;
- every `ThinAllocation` of a `_SharedHeader` is counted exactly once: it is
  created only by `_Shared.__init__` (count 1) or the copy constructor
  (count + 1) and leaked only by `__deinit__` (count - 1), and the value and
  header are freed only when the count reaches zero; `_Shared` exposes only
  the immutable `owned` and `count`.
"""

from std.atomic import Atomic, Ordering, fence
from std.memory import MaybeUninit, MutOpaquePointer, OwnedPointer
from std.memory.alloc import ThinAllocation
from std.reflection import reflect

from .http import Response
from ._field_built import _FieldBuilt

comptime _Box = MutOpaquePointer[MutUntrackedOrigin]

comptime _Call[F: AnyType] = def(
    F, List[String], List[UInt8]
) raises thin -> Response
"""Calls a stored `F` with the raw argument strings of a matched route and
the request's body bytes, both borrowed and passed through unread (M3-040).
No adapter raises (each answers its own 400s and turns a handler error into
a response), so a raise out of `invoke` is a server fault."""


def _unsafe_erase[F: Movable & Deinitable](var owner: OwnedPointer[F]) -> _Box:
    return (
        owner^.unsafe_take_allocation().unsafe_leak().unsafe_bitcast[NoneType]()
    )


def _unsafe_invoke_box[
    F: Movable & Deinitable, //, call: _Call[F]
](box: _Box, args: List[String], bytes: List[UInt8]) raises -> Response:
    return call(box.unsafe_bitcast[F]()[], args, bytes)


def _unsafe_drop_box[F: Movable & Deinitable](box: _Box):
    _ = OwnedPointer[F](unsafe_from_opaque_pointer=box)


@fieldwise_init
struct _Header(Movable):
    """A boxed value and the two functions instantiated for its type."""

    var _invoke: def(_Box, List[String], List[UInt8]) raises thin -> Response
    var _drop: def(_Box) thin
    var _value: _Box


struct _Erased(Movable):
    """Owns one handler value of a type known only at registration."""

    var _header: ThinAllocation[_Header]

    def __init__[
        F: Movable & Deinitable, //, call: _Call[F]
    ](out self, var value: F):
        """Boxes `value`; `call` is how `invoke` will call it.

        `call` shares `F` with `value`, so a trampoline for another type is
        rejected here at compile time.
        """
        var header = _Header(
            _unsafe_invoke_box[call],
            _unsafe_drop_box[F],
            _unsafe_erase(OwnedPointer(value^)),
        )
        self._header = (
            OwnedPointer(header^).unsafe_take_allocation().into_thin()
        )

    def __deinit__(deinit self):
        var header = self._header^.unsafe_leak()
        header[]._drop(header[]._value)
        _ = OwnedPointer[_Header](unsafe_from_raw_pointer=header)

    def invoke(self, args: List[String], bytes: List[UInt8]) raises -> Response:
        """Calls the boxed value with `args` and `bytes`; raises if `call`
        does."""
        ref header = self._header.unsafe_ptr()[]
        return header._invoke(header._value, args, bytes)


struct _SharedHeader[S: Movable & Deinitable](Movable):
    """The heap part of a `_Shared`: how many handles exist, and the value."""

    var count: Atomic[UInt64]
    var value: OwnedPointer[Self.S]

    def __init__(out self, var value: Self.S):
        self.count = Atomic(UInt64(1))
        self.value = OwnedPointer(value^)


struct _Shared[S: Movable & Deinitable](Copyable, Movable):
    """Owns one share of a reference-counted value of type `S`."""

    var _header: ThinAllocation[_SharedHeader[Self.S]]

    def __init__(out self, var value: Self.S):
        """Moves `value` into a new header with a count of one."""
        self._header = (
            OwnedPointer(_SharedHeader(value^))
            .unsafe_take_allocation()
            .into_thin()
        )

    def __init__(out self, *, copy: Self):
        """A second handle on `copy`'s header; the count goes up by one, as
        for `ArcPointer` (relaxed)."""
        var header = (
            copy._header.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        _ = header[].count.fetch_add[ordering=Ordering.RELAXED](1)
        self._header = ThinAllocation(unsafe_owned_ptr=header)

    def __deinit__(deinit self):
        """Drops one share; the last drops the value and frees the header
        (release decrement, acquire fence, as for `ArcPointer`)."""
        var header = self._header^.unsafe_leak()
        if header[].count.fetch_sub[ordering=Ordering.RELEASE](1) != 1:
            return
        fence[ordering=Ordering.ACQUIRE]()
        _ = OwnedPointer[_SharedHeader[Self.S]](unsafe_from_raw_pointer=header)

    def count(self) -> UInt64:
        """How many handles share the value."""
        return self._header.unsafe_ptr()[].count.load()

    def owned(
        self,
    ) -> ref[origin_of(self._header.unsafe_ptr()[].value)] OwnedPointer[Self.S]:
        """The value's `OwnedPointer`, immutable: the receiver is borrowed.
        This line is what makes `State[]` read-only."""
        return self._header.unsafe_ptr()[].value


def _build_record[
    S1: AnyType,
    S2: AnyType,
    //,
    T: _FieldBuilt,
    E: Movable & Deinitable,
    convert: def[F: Movable & Deinitable, i: Int](S1, S2) thin raises E -> F,
    at: Int,
](args: S1, bytes: S2) raises E -> T:
    """Builds a `T` field by field without calling any of its initializers:
    field `i`, of type `F`, is `convert[F, at + i](args, bytes)`, in field
    order, from two borrowed sources it passes through unread. `T` is a
    route-value record (M3-061) or a `JsonFields` struct (M3-082), the only
    refinements of `_FieldBuilt`, so no other type can be built this way;
    `app.mojo` calls it only for a record the registration rules accepted,
    whose fields they restrict to route values, and `json.mojo` only for a
    struct whose every field is a JSON kind. A struct with no field is
    built with nothing written.

    Invariant, which the compiler does not check (`MaybeUninit` does not
    track which fields are initialized):
    - each field is written once, as its own type, at its reflected offset
      (`reflect[T].field_offset`), so alignment and padding are the
      compiler's; field types are refined with `conforms_to`, which Mojo
      1.1.0 checks, never `downcast`, which it does not;
    - nothing is destroyed before field 0 is written, and after `k` fields
      exactly fields `0` to `k-1` are initialized;
    - when converting field `k` raises, field `k` was never written, each of
      fields `0` to `k-1` is moved out and destroyed once, in field order
      (the order Mojo destroys a struct's fields in), the storage is
      forgotten without running `T`'s destructor, and the error propagates;
    - on success every field is initialized, the storage is taken as the
      `T`, whose destructor then runs once, where its owner drops it, and
      this function owns nothing;
    - no field is destroyed twice or read uninitialized.
    """
    comptime r = reflect[T]
    comptime count = r.field_count()
    comptime types = r.field_types()
    var storage = MaybeUninit[T]()
    var base = storage.unsafe_ptr().unsafe_bitcast[UInt8]()
    comptime for i in range(count):
        comptime F = types[i]
        comptime assert conforms_to(F, Movable & Deinitable)
        comptime if conforms_to(F, Movable & Deinitable):
            try:
                base.unsafe_offset(r.field_offset[index=i]()).unsafe_bitcast[
                    F
                ]().unsafe_write(convert[F, at + i](args, bytes))
            except e:
                comptime for j in range(i):
                    comptime G = types[j]
                    comptime if conforms_to(G, Movable & Deinitable):
                        _ = (
                            base.unsafe_offset(r.field_offset[index=j]())
                            .unsafe_bitcast[G]()
                            .unsafe_take_pointee()
                        )
                storage^.unsafe_forget()
                raise e^
    return storage^.unsafe_assume_init()
