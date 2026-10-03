# Must not compile (M3-004): the review's case. A second handle cannot
# replace the shared value: the sealed box has no subscript, unlike the
# ArcPointer field it replaces (state_storage_known_gaps/arc_alias_swap.mojo).
# Expected diagnostic (checked by scripts/check.sh): '_Shared[Db]' is not subscriptable
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
    b._shared[] = OwnedPointer(Db(2))
    print(r.n)
