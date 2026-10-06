# Must not compile: a stateful `put` handler registered without its state, so
# its `State` sits in a request slot; the message names the method. Decision:
# docs/history/architecture-decisions.md, "HTTP methods decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: State is injected application state, not the request body; a stateful put handler takes State first and the body last, and the state is the registration's second argument
from muntin import App, FromBody, State


struct P(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(p: State[P], body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.put["/x"](h)
