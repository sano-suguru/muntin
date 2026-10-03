# Must not compile (M3-004): a second handle cannot swap a new value's
# OwnedPointer into the box: the accessor's reference is immutable.
# Expected diagnostic (checked by scripts/check.sh): value passed to mutable argument 'lhs' must be mutable
from std.memory import OwnedPointer
from state_storage_spike import State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def main():
    var a = State(Db(1))
    var b = a.copy()
    ref r = a[]
    var other = OwnedPointer(Db(2))
    swap(b._shared.owned(), other)
    print(r.n)
