# Must not compile (M3-004): the shared value cannot be moved out of the
# box through a second handle.
# Expected diagnostic (checked by scripts/check.sh): expression does not designate a value with an origin
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
    var v = b._shared.owned()^.into_inner()
    print(r.n)
