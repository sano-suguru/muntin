# Must not compile: the handler borrows the route's handle; `var db:
# State[Db]` does not convert to the registered function type (M3-006), so the
# call selects no overload (M3-015).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(var db: State[Db], body: Note) thin -> String' to 'def(State[S], var A) raises Never thin -> String'
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


def h(var db: State[Db], body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.post["/x"](h, State(Db(1)))
