# Must not compile: a route with a path parameter, a stateful handler that
# takes no route value; the state is not a route value (M3-003).
# Expected diagnostic (checked by scripts/check.sh): route declares a path parameter but the handler takes none

from muntin import App, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db]) -> String:
    return String(db[].n)


def main():
    var app = App()
    app.get["/x/{id}"](h, State(Db(1)))
