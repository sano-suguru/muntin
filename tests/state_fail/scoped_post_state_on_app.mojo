# Must not compile (A2): a stateful handler registered on the app's post
# reaches the generic body overload; the State guard names the registrar
# (M3-001).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: State is injected application state, not the request body; register the handler through app.with_state(state)
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
    app.post["/x"](h)
