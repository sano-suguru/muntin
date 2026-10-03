# Must not compile: on post, the body stays last; a stateful handler with
# the state after the body has no overload (M3-001).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(var body: Name, db: State[Db]) thin -> String' to 'def(State[S], var B) raises Never thin -> String'
from muntin import FromBody, Request, Response
from state_spike import State, StateApp


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


struct Name(FromBody, Movable):
    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(var body: Name, db: State[Db]) -> String:
    return body.text


def main():
    var app = StateApp()
    app.post["/x"](h, State(Db(1)))
