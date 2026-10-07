# Must not compile: the stateful `put` form, an `Optional[String]` and an
# `Int` before the body, the optional one at the path placeholder of
# `/x/{a}?{b}`; the path-position rule is checked before the body. Decision:
# docs/history/architecture-decisions.md, "Optional query values decision
# (M3-024)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: an Optional route value binds a query parameter; route values bind the path parameters first, then the query parameters
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


def h(p: State[P], a: Optional[String], b: Int, body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.put["/x/{a}?{b}"](h, State(P(1)))
