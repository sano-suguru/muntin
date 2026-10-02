# Must not compile: State gives read-only access; even a `mut` handle
# yields an immutable reference (M3-001).
# Expected diagnostic (checked by scripts/check.sh): expression must be mutable for in-place operator destination
from muntin import Request, Response
from state_spike import State, StateApp


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def bump(mut db: State[Db]):
    db[].n += 1


def main():
    var db = State(Db(1))
    bump(db)
