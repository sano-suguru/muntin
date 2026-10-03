# Must not compile (M3-004): a second handle cannot mutate the shared value
# (here, free a list a reference from the first handle points into).
# Expected diagnostic (checked by scripts/check.sh): invalid use of mutating method
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
    ref names = a[].names
    b._shared.owned()[].names.clear()
    print(len(names))
