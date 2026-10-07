# Must not compile: the stateful `patch` form, a `String` and an `Int`
# route value and a body on a route with one placeholder. Decision:
# docs/history/architecture-decisions.md, "Several route values decision
# (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes two route values and the request body; route must declare exactly two path or query parameters
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


def h(p: State[P], a: String, b: Int, body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.patch["/x/{a}"](h, State(P(1)))
