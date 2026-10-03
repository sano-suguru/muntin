# Must not compile: a stateful Int handler on a route without a path or
# query parameter (M3-003).
# Expected diagnostic (checked by scripts/check.sh): handler takes one Int parameter; route must declare exactly one path or query parameter

from muntin import App, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db], id: Int) -> String:
    return String(db[].n + id)


def main():
    var app = App()
    app.get["/x"](h, State(Db(1)))
