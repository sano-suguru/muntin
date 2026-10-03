# Must not compile (M3-004): state[] is read-only through every handle.
# Expected diagnostic (checked by scripts/check.sh): expression must be mutable for in-place operator destination
from std.memory import OwnedPointer
from state_storage_spike import State, _Shared


struct Db(Movable):
    var n: Int
    var names: List[String]

    def __init__(out self, n: Int):
        self.n = n
        self.names = List[String]()


def bump(mut db: State[Db]):
    db[].n += 1


def main():
    var db = State(Db(1))
    bump(db)
