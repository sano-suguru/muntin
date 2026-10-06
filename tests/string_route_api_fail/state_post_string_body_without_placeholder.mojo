# Must not compile: the stateful form of
# post_string_body_without_placeholder.mojo. Decision:
# docs/history/architecture-decisions.md, "Route-value decoding and String
# route values decision (M3-018)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one String parameter and the request body; route must declare exactly one path or query parameter
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


def h(p: State[P], name: String, body: Note) -> String:
    return name


def main():
    var app = App()
    app.post["/x"](h, State(P(1)))
