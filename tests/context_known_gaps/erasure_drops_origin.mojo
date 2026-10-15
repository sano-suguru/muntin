# Must build, and is never run (scripts/check.sh builds it only; run, it touches
# freed memory). Evidence for docs/history/architecture-decisions.md,
# "Request context storage decision (M3-065)": a store that erases a value's
# type drops the value's origin even if nothing ever restores the value, so no
# key, however exact, makes such a store sound. `middleware` stores a guard on
# its local `token`; the checker ends `token` at its last use, because
# `Store`'s type does not carry that origin; dropping the store runs the
# guard's destructor, which updates the freed value through the dead borrow (AddressSanitizer:
# heap-use-after-free, pull request #N). A generic `set[T]` cannot refuse such
# a `T`: generic `==` ignores origin identity
# (tests/registration_known_gaps/generic_equality_ignores_origin_identity.mojo).
#
# If this file stops building, Mojo refuses to erase a value that borrows a
# local: re-measure open context storage.

from std.memory import MutOpaquePointer, OwnedPointer

comptime _Box = MutOpaquePointer[MutUntrackedOrigin]


def _drop[T: Movable & Deinitable](box: _Box):
    _ = OwnedPointer[T](unsafe_from_opaque_pointer=box)


struct Store(Movable):
    var box: Optional[_Box]
    var drop: Optional[def(_Box) thin -> None]

    def __init__(out self):
        self.box = None
        self.drop = None

    def set[T: Movable & Deinitable](mut self, var value: T):
        self.box = (
            OwnedPointer(value^)
            .unsafe_take_allocation()
            .unsafe_leak()
            .unsafe_bitcast[NoneType]()
        )
        self.drop = _drop[T]

    def __deinit__(deinit self):
        if self.box:
            self.drop.value()(self.box.value())


struct Guard[o: Origin[mut=True]](Movable):
    var p: Pointer[Int, Self.o]

    def __init__(out self, ref[Self.o] x: Int):
        self.p = Pointer(to=x)

    def __deinit__(deinit self):
        self.p[] += 1


@no_inline
def middleware(mut store: Store):
    var token = OwnedPointer(42)
    store.set(Guard(token[]))


def main():
    var store = Store()
    middleware(store)
    _ = store^
