# Must not compile: the stateful `patch` form, one `Optional[String]` and a
# body, on a literal with a path placeholder. Decision:
# docs/history/architecture-decisions.md, "Optional query values decision
# (M3-024)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one Optional route value and the request body; route must declare exactly one query parameter and no path parameter
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


def h(p: State[P], a: Optional[String], body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.patch["/x/{a}"](h, State(P(1)))
