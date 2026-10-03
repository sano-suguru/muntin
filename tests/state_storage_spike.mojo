# M3-004 state-storage decision spike, library side. Not production code:
# it models the selected candidate A, a sealed shared box behind the
# unchanged public `State[S]` API, separately from the application module
# (tests/test_spike_state_storage.mojo) that defines the state types. The
# box would live in Muntin's private storage module, where unsafe
# operations are allowed (scripts/check_unsafe.sh). check.sh builds it
# through that test (--Werror) and through
# tests/state_storage_lib_only/driver.mojo; test.sh runs it. Decision and
# evidence: docs/ARCHITECTURE.md, "State storage decision (M3-004)".
# Must-not-compile evidence: tests/state_storage_fail. Must-build evidence
# (rejected candidates and the residual): tests/state_storage_known_gaps.
#
# Why a box: `ArcPointer.__getitem__` returns a mutable reference through
# any handle, borrowed ones included, and Mojo 1.1.0 has no private
# fields. An `ArcPointer` field of `State` therefore lets code holding
# another copy free memory a reference from `state[]` points into,
# through public std API alone (tests/state_storage_known_gaps).
#
#   _Shared[S]  one field, a move-only `ThinAllocation` of a heap
#               `_SharedHeader` (an atomic count and an `OwnedPointer[S]`).
#               Its only accessors return immutable references. Copying it
#               increments the count; dropping the last copy drops the
#               value and frees the header. Reaching the header otherwise
#               takes `unsafe_ptr()` or the stdlib's private
#               `ThinAllocation._ptr`, as for `_Erased`.
#   State[S]    the public API of M3-001, unchanged: `State(value)`,
#               `.copy()`, `state[]` read-only. The `OwnedPointer` gives the
#               reference from `state[]` an origin interior to the handle,
#               so using it after the handle is reassigned or moved is a
#               compile error. Read-only rests on one line: `owned(self)`
#               borrows its receiver, so every reference it yields is
#               immutable.

from std.atomic import Atomic, Ordering, fence
from std.memory import OwnedPointer
from std.memory.alloc import ThinAllocation

from muntin import Response
from muntin._handler_storage import _Erased


struct _SharedHeader[S: Movable & Deinitable](Movable):
    """The heap part of a `_Shared`: how many handles exist, and the value."""

    var count: Atomic[UInt64]
    var value: OwnedPointer[Self.S]

    def __init__(out self, var value: Self.S):
        self.count = Atomic(UInt64(1))
        self.value = OwnedPointer(value^)


struct _Shared[S: Movable & Deinitable](Copyable, Movable):
    """A reference-counted handle to one value of type `S`, sealed: code
    outside the storage module gets only immutable references to the value
    and cannot replace, alias or move the header without an `unsafe_`-named
    call (or the stdlib's private `ThinAllocation._ptr`)."""

    var _header: ThinAllocation[_SharedHeader[Self.S]]

    def __init__(out self, var value: Self.S):
        self._header = (
            OwnedPointer(_SharedHeader(value^))
            .unsafe_take_allocation()
            .into_thin()
        )

    def __init__(out self, *, copy: Self):
        var header = (
            copy._header.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        _ = header[].count.fetch_add[ordering=Ordering.RELAXED](1)
        self._header = ThinAllocation(unsafe_owned_ptr=header)

    def __deinit__(deinit self):
        var header = self._header^.unsafe_leak()
        if header[].count.fetch_sub[ordering=Ordering.RELEASE](1) != 1:
            return
        fence[ordering=Ordering.ACQUIRE]()
        _ = OwnedPointer[_SharedHeader[Self.S]](unsafe_from_raw_pointer=header)

    def count(self) -> UInt64:
        """How many handles share the value (for tests)."""
        return self._header.unsafe_ptr()[].count.load()

    def owned(
        self,
    ) -> ref[origin_of(self._header.unsafe_ptr()[].value)] OwnedPointer[Self.S]:
        """The value's `OwnedPointer`, immutable: the receiver is borrowed."""
        return self._header.unsafe_ptr()[].value


struct State[S: Movable & Deinitable](Copyable, Movable):
    """M3-001's public `State[S]`, over the sealed box."""

    var _shared: _Shared[Self.S]

    def __init__(out self, var value: Self.S):
        self._shared = _Shared(value^)

    def __getitem__(self) -> ref[origin_of(self._shared.owned()[])] Self.S:
        """Read-only because `_Shared.owned` borrows its receiver; interior
        to this handle because `OwnedPointer[]` is."""
        return self._shared.owned()[]


# Per-request borrowing through production `_Erased`: a handler and one
# copy of the handle boxed together, called with the handle by borrow, as
# M3-003's `_Bound` and `_call_state_none` do.


struct _BoundSpike[S: Movable & Deinitable](Movable):
    var handler: def(State[Self.S]) thin -> String
    var state: State[Self.S]

    def __init__(
        out self,
        handler: def(State[Self.S]) thin -> String,
        state: State[Self.S],
    ):
        self.handler = handler
        self.state = state.copy()


def _call_bound[
    S: Movable & Deinitable
](bound: _BoundSpike[S], args: List[String]) -> Response:
    return Response.text(bound.handler(bound.state))


def box_handler[
    S: Movable & Deinitable
](handler: def(State[S]) thin -> String, state: State[S]) -> _Erased:
    """Boxes `handler` with one copy of `state`, as a registration would."""
    return _Erased.__init__[call=_call_bound[S]](_BoundSpike(handler, state))
