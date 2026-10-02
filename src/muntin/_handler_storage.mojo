"""Private handler storage for `App`: a typed heap box with pointer erasure.

Not part of Muntin's public API; nothing here is exported from `muntin`.
This is the only module in `src/muntin` allowed to use unsafe pointer or
ownership operations (`scripts/check_unsafe.sh` fails otherwise). Decision
and evidence: docs/ARCHITECTURE.md, "Handler storage decision (M2)" and its
"Production implementation (M2-004)".

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
without writing `unsafe`.

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
  read, and released (`_Erased`).

Invariant, which the compiler does not check (`MutUntrackedOrigin` is an
origin the lifetime checker does not track):
- `_value` points to one live `F` allocated by `OwnedPointer[F]`, and its
  header is owned by exactly one `_Erased`;
- a header is written only by `_Erased.__init__`, which instantiates
  `_unsafe_invoke_box` and `_unsafe_drop_box` with the same `F` it allocated, so the
  pointer is only ever restored as that `F`;
- `_Erased` exposes only `invoke`; other modules in `src/muntin` import
  only `_Erased` (`check_unsafe.sh`);
- `_Erased` is `Movable` and not `Copyable`: a move transfers the handle
  without running `__deinit__` on the source, `__deinit__` frees the value
  and then the header exactly once, and `invoke` borrows the owning
  `_Erased`, so both allocations outlive every call.
"""

from std.memory import MutOpaquePointer, OwnedPointer
from std.memory.alloc import ThinAllocation

from .http import Response

comptime _Box = MutOpaquePointer[MutUntrackedOrigin]

comptime _Call[F: AnyType] = def(F, List[String]) raises thin -> Response
"""Calls a stored `F` with the raw argument strings of a matched route.
No adapter raises (each answers its own 400s and turns a handler error into
500), so a raise out of `invoke` is a server fault."""


def _unsafe_erase[F: Movable & Deinitable](var owner: OwnedPointer[F]) -> _Box:
    return (
        owner^.unsafe_take_allocation().unsafe_leak().unsafe_bitcast[NoneType]()
    )


def _unsafe_invoke_box[
    F: Movable & Deinitable, //, call: _Call[F]
](box: _Box, args: List[String]) raises -> Response:
    return call(box.unsafe_bitcast[F]()[], args)


def _unsafe_drop_box[F: Movable & Deinitable](box: _Box):
    _ = OwnedPointer[F](unsafe_from_opaque_pointer=box)


@fieldwise_init
struct _Header(Movable):
    """A boxed value and the two functions instantiated for its type."""

    var _invoke: def(_Box, List[String]) raises thin -> Response
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

    def invoke(self, args: List[String]) raises -> Response:
        """Calls the boxed value with `args`; raises if `call` does."""
        ref header = self._header.unsafe_ptr()[]
        return header._invoke(header._value, args)
