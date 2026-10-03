# Must not compile: a reference is interior to the handle it was taken
# through, also when that handle is a copy (M3-003).
# Expected diagnostic (checked by scripts/check.sh): use of invalidated interior reference
from muntin import State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def main():
    var db = State(Db(1))
    var copy = db.copy()
    ref r = copy[]
    copy = State(Db(2))
    print(r.n, db[].n)
