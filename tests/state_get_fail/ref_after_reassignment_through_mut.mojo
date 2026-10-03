# Must not compile: reassigning a handle through a `mut` argument also
# invalidates references taken from it (M3-003).
# Expected diagnostic (checked by scripts/check.sh): use of invalidated interior reference
from muntin import State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def replace(mut db: State[Db]):
    db = State(Db(2))


def main():
    var db = State(Db(1))
    ref r = db[]
    replace(db)
    print(r.n)
