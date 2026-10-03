# Must not compile: state[] is read-only inside a registered POST handler
# (M3-006).
# Expected diagnostic (checked by scripts/check.sh): expression must be mutable in assignment
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


def h(db: State[Db], body: Note) -> String:
    db[].n = 2
    return body.text


def main():
    var app = App()
    app.post["/x"](h, State(Db(1)))
