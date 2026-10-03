# Must not compile (M3-004): one box's header cannot be copied over
# another's (two owners of one header, then a double free).
# Expected diagnostic (checked by scripts/check.sh): cannot be implicitly copied
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
    b._shared._header = a._shared._header
