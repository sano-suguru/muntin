# Must not compile (M3-004): a reference from state[] cannot be returned as
# a reference into its handle.
# Expected diagnostic (checked by scripts/check.sh): cannot return reference with incompatible origin
from std.memory import OwnedPointer
from state_storage_spike import State, _Shared


struct Db(Movable):
    var n: Int
    var names: List[String]

    def __init__(out self, n: Int):
        self.n = n
        self.names = List[String]()


def value(db: State[Db]) -> ref[db] Db:
    return db[]


def main():
    var db = State(Db(1))
    print(value(db).n)
