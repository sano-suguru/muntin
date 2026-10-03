# Must not compile: POST has no stateful shape without a body; a handler taking
# only State, registered with its state, matches no post overload (M3-006).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(db: State[Db]) thin -> String' to 'def(State[S], var B) raises Never thin -> String'
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


def h(db: State[Db]) -> String:
    return String(db[].n)


def main():
    var app = App()
    app.post["/x"](h, State(Db(1)))
