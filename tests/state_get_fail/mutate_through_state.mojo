# Must not compile: state[] is read-only through every handle, also a
# `mut` one (M3-003).
# Expected diagnostic (checked by scripts/check.sh): expression must be mutable for in-place operator destination
from muntin import App, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def bump(mut db: State[Db]):
    db[].n += 1


def main():
    var db = State(Db(1))
    bump(db)
