# Must not compile: a handler takes at most one State, first. On post a
# second State reaches the body slot and is rejected (M3-001).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a handler takes at most one State, as its first parameter
from muntin import Request, Response
from state_spike import State, StateApp


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db], other: State[Db]) -> String:
    return String(db[].n)


def main():
    var app = StateApp()
    app.post["/x"](h, State(Db(1)))
