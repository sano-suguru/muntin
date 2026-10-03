# Must not compile: a stateful handler registered without its state
# matches no one-argument get overload (M3-003).
# Expected diagnostic (checked by scripts/check.sh): missing required argument: 'state'
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
