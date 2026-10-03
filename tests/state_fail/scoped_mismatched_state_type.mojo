# Must not compile (A2): the registrar fixes S; a handler for another state
# type has no overload on it (M3-001).
# Expected diagnostic (checked by scripts/check.sh): .db.S of the first type is 'Db' but the second type is 'Cache'
from muntin import FromBody, Request, Response
from scoped_state_spike import ScopedApp
from state_spike import State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


struct Cache(Movable):
    def __init__(out self):
        pass


def h(db: State[Db], id: Int) -> String:
    return String(db[].n + id)


def main():
    var app = ScopedApp()
    app.with_state(State(Cache())).get["/x/{id}"](h)
