# Must not compile: the state is not a route value; the placeholder count
# check is unchanged by it (M3-001).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: route declares a path parameter but the handler takes none
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
    app.get["/x/{id}"](h, State(Db(1)))
