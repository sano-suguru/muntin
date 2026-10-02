# Must not compile: a stateful handler registered without its state on get
# matches no one-argument overload (M3-001).
# Expected diagnostic (checked by scripts/check.sh): missing required argument: 'state'
from muntin import Request, Response
from state_spike import State, StateApp


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db]) -> String:
    return String(db[].n)


def main():
    var app = StateApp()
    app.get["/x"](h)
