# Must not compile: a reference from state[] cannot be returned as a
# reference into the handle (M3-003).
# Expected diagnostic (checked by scripts/check.sh): cannot return reference with incompatible origin
from muntin import State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def value(db: State[Db]) -> ref[db] Db:
    return db[]


def main():
    var db = State(Db(1))
    print(value(db).n)
