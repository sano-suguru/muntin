# Must not compile: a stateful handler registered without its state on
# post reaches the generic body overload with B = State[Db]; the State guard
# names the mistake instead of the FromBody message (M3-001).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: State is injected application state, not the request body; pass the state as the registration's second argument
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
    app.post["/x"](h)
