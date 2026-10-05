# Must not compile: a state argument for a POST handler that takes none
# selects no overload; the state is never silently ignored (M3-006, M3-015).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(body: Note) thin -> String' to 'def(State[S], var A) raises Never thin -> String'
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


def h(body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.post["/x"](h, State(Db(1)))
