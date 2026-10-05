# Must not compile: State is the first parameter of a stateful handler, never
# after the route value (M3-003). The stateful overloads fix `State[S]` first,
# so the call selects no overload (M3-015).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(id: Int, db: State[Db]) thin -> String' to 'def(State[S], var A) raises Never thin -> String'
from muntin import App, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(id: Int, db: State[Db]) -> String:
    return String(db[].n + id)


def main():
    var app = App()
    app.get["/x/{id}"](h, State(Db(1)))
