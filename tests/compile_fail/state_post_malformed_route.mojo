# Must not compile: a stateful POST registration with a malformed route
# literal (M3-006).
# Expected diagnostic (checked by scripts/check.sh): malformed route literal
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


def h(db: State[Db], id: Int, body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.post["/x/{id"](h, State(Db(1)))
