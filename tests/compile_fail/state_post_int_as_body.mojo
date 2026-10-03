# Must not compile: a stateful handler taking State then Int registered on
# POST: Int is a route value, never the body (M3-006).
# Expected diagnostic (checked by scripts/check.sh): Int is a route-value type, never the request body; the body parameter's type must conform to FromBody
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


def h(db: State[Db], id: Int) -> String:
    return String(id)


def main():
    var app = App()
    app.post["/x"](h, State(Db(1)))
