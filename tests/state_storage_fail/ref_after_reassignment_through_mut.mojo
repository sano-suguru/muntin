# Must not compile (M3-004): reassigning a handle through a `mut` argument
# invalidates references taken from it.
# Expected diagnostic (checked by scripts/check.sh): use of invalidated interior reference
from std.memory import OwnedPointer
from state_storage_spike import State, _Shared


struct Db(Movable):
    var n: Int
    var names: List[String]

    def __init__(out self, n: Int):
        self.n = n
        self.names = List[String]()


def replace(mut db: State[Db]):
    db = State(Db(2))


def main():
    var db = State(Db(1))
    ref r = db[]
    replace(db)
    print(r.n)
