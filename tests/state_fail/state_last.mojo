# Must not compile: State is the first parameter of a stateful handler,
# never after the route value (M3-001; DX section 8's conceptual
# `def get_user(id: Int, state: State[AppState])` is not the decided shape).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(id: Int, db: State[Db]) thin -> String' to 'def(State[S], Int) raises Never thin -> String'
from muntin import Request, Response
from state_spike import State, StateApp


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(id: Int, db: State[Db]) -> String:
    return String(db[].n + id)


def main():
    var app = StateApp()
    app.get["/x/{id}"](h, State(Db(1)))
