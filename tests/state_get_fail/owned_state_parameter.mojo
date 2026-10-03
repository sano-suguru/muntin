# Must not compile: the handler borrows the route's handle; a handler
# declaring `var db: State[Db]` does not convert to the registered function
# type (M3-003).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(var db: State[Db]) thin -> String' to 'def(State[S]) raises Never thin -> String'
from muntin import App, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(var db: State[Db]) -> String:
    return String(db[].n)


def main():
    var app = App()
    app.get["/x"](h, State(Db(1)))
