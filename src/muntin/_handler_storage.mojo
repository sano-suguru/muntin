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

Unsafe operations, all in this module:
- `OwnedPointer.unsafe_take_allocation` + `Allocation.unsafe_leak`: the
  allocation stops being owned by an `OwnedPointer[F]` (`_erase`);
- `Pointer.unsafe_bitcast`: `F` to `NoneType` when erasing, `NoneType` to
  `F` when invoking (`_erase`, `_invoke_box`);
- `[]` on the untracked `Pointer[F, MutUntrackedOrigin]` (`_invoke_box`);
- `OwnedPointer(unsafe_from_opaque_pointer=)`: ownership restored as `F`
  and released (`_drop_box`).

Invariant, which the compiler does not check (`MutUntrackedOrigin` is an
origin the lifetime checker does not track, and Mojo 1.1.0 has no private
fields):
- `_box` points to one live `F` allocated by `OwnedPointer[F]`, owned by
  exactly one `_Erased`;
- `_box`, `_invoke` and `_drop` are set only by `_Erased.__init__` (and
  carried unchanged by the synthesized move), which instantiates `_invoke_box` and `_drop_box` with the same `F` it
  allocated, so the pointer is only ever restored as that `F`;
- the pointer never leaves this module: `_Erased` exposes only `invoke`,
  and other modules import only `_Erased` (`check_unsafe.sh`);
- `_Erased` is `Movable` and not `Copyable`: a move transfers the pointer
  without running `__deinit__` on the source, and `__deinit__` frees the
  allocation exactly once, so the allocation outlives every `invoke`.
"""

from std.memory import MutOpaquePointer, OwnedPointer

from .http import Response

comptime _Box = MutOpaquePointer[MutUntrackedOrigin]

comptime _Call[F: AnyType] = def(F, List[String]) raises thin -> Response
"""Calls a stored `F` with the raw argument strings of a matched route.
Raising means an argument failed to convert."""


def _erase[F: Movable & Deinitable](var owner: OwnedPointer[F]) -> _Box:
    return (
        owner^.unsafe_take_allocation().unsafe_leak().unsafe_bitcast[NoneType]()
    )


def _invoke_box[
    F: Movable & Deinitable, //, call: _Call[F]
](box: _Box, args: List[String]) raises -> Response:
    return call(box.unsafe_bitcast[F]()[], args)


def _drop_box[F: Movable & Deinitable](box: _Box):
    _ = OwnedPointer[F](unsafe_from_opaque_pointer=box)


struct _Erased(Movable):
    """Owns one handler value of a type known only at registration."""

    var _box: _Box
    var _invoke: def(_Box, List[String]) raises thin -> Response
    var _drop: def(_Box) thin

    def __init__[
        F: Movable & Deinitable, //, call: _Call[F]
    ](out self, var value: F):
        """Boxes `value`; `call` is how `invoke` will call it.

        `call` shares `F` with `value`, so a trampoline for another type is
        rejected here at compile time.
        """
        self._box = _erase(OwnedPointer(value^))
        self._invoke = _invoke_box[call]
        self._drop = _drop_box[F]

    def __deinit__(deinit self):
        self._drop(self._box)

    def invoke(self, args: List[String]) raises -> Response:
        """Calls the boxed value with `args`; raises if `call` does."""
        return self._invoke(self._box, args)
