# Must not compile (M3-004): the box's accessor is immutable, so a second
# handle cannot assign a new value's OwnedPointer through it.
# Expected diagnostic (checked by scripts/check.sh): expression must be mutable in assignment
from std.memory import OwnedPointer
from state_storage_spike import State, _Shared


struct Db(Movable):
    var n: Int
    var names: List[String]

    def __init__(out self, n: Int):
        self.n = n
        self.names = List[String]()


def main():
    var a = State(Db(1))
    var b = a.copy()
    ref r = a[]
    b._shared.owned() = OwnedPointer(Db(2))
    print(r.n)
