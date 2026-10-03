# Must not compile: a stateful route-value-then-body POST handler registered
# without its state (M3-006).
# Expected diagnostic (checked by scripts/check.sh): missing required argument: 'state'
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
    app.post["/x/{id}"](h)
