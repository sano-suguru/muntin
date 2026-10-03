# Must not compile: a stateful POST handler taking a second State as its body
# (M3-006). One injected slot: the first parameter.
# Expected diagnostic (checked by scripts/check.sh): a handler takes at most one State, as its first parameter
from muntin import App, FromBody, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


struct Note(FromBody):
    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(db: State[Db], other: State[Db]) -> String:
    return String(other[].n)


def main():
    var app = App()
    app.post["/x"](h, State(Db(1)))
