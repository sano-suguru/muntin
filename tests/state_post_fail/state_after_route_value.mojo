# Must not compile: State is the first parameter of a stateful POST handler,
# never after the route value (M3-006). The stateful overloads fix `State[S]`
# first, so the call selects no overload (M3-015).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(id: Int, db: State[Db], body: Note) thin -> String' to 'def(State[S], var A, var B) raises Never thin -> String'
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


def h(id: Int, db: State[Db], body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.post["/x/{id}"](h, State(Db(1)))
