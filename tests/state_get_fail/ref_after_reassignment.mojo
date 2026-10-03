# Must not compile: a reference from state[] is interior to its handle;
# using it after the handle is reassigned would read a dropped value, and
# the compiler rejects it (M3-003).
# Expected diagnostic (checked by scripts/check.sh): use of invalidated interior reference
from muntin import State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def main():
    var db = State(Db(1))
    ref r = db[]
    db = State(Db(2))
    print(r.n)
