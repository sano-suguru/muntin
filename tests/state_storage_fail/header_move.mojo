# Must not compile (M3-004): one box's header cannot be moved over
# another's or out of its box.
# Expected diagnostic (checked by scripts/check.sh): abandoned without being explicitly destroyed
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
    var b = State(Db(2))
    b._shared._header = a._shared._header^
