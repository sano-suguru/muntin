# Must not compile: state[] is read-only inside a registered handler
# (M3-003).
# Expected diagnostic (checked by scripts/check.sh): expression must be mutable in assignment
from muntin import App, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db]) -> String:
    db[].n = 2
    return String(db[].n)


def main():
    var app = App()
    app.get["/x"](h, State(Db(1)))
