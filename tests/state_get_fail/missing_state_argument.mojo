# Must not compile: a stateful handler registered without its state (M3-003)
# selects get's stateless one-slot overload, whose rule check reports the
# State rule (M3-015).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: State is injected application state; a stateful get handler takes State first, and the state is the registration's second argument
from muntin import App, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db]) -> String:
    return String(db[].n)


def main():
    var app = App()
    app.get["/x"](h)
