# Must not compile (M3-004): a reference from state[] is interior to its
# handle; reassigning the handle invalidates it.
# Expected diagnostic (checked by scripts/check.sh): use of invalidated interior reference
from std.memory import OwnedPointer
from state_storage_spike import State, _Shared


struct Db(Movable):
    var n: Int
    var names: List[String]

    def __init__(out self, n: Int):
        self.n = n
        self.names = List[String]()


def main():
    var db = State(Db(1))
    ref r = db[]
    db = State(Db(2))
    print(r.n)
