# Must not compile (A2): the registrar borrows the app; moving the app
# while the registrar is still used is rejected (M3-001).
# Expected diagnostic (checked by scripts/check.sh): use of uninitialized value 'app'
from muntin import FromBody, Request, Response
from scoped_state_spike import ScopedApp
from state_spike import State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db]) -> String:
    return String(db[].n)


def main():
    var app = ScopedApp()
    var api = app.with_state(State(Db(1)))
    var moved = app^
    api.get["/x"](h)
