# Must not compile: a stateful handler on a malformed route literal (M3-003).
# Expected diagnostic (checked by scripts/check.sh): malformed route literal

from muntin import App, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db], id: Int) -> String:
    return String(db[].n + id)


def main():
    var app = App()
    app.get["/x/{id"](h, State(Db(1)))
