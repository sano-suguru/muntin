# Must not compile: a route value and two bodies on `put` select its
# slot-arity-3 overload, which reports that a handler takes one body, last.
# Decisions: docs/history/architecture-decisions.md, "HTTP methods decision
# (M3-020)" and "Several route values decision (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a put handler takes one request body, as its last parameter
from muntin import App, FromBody


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(a: Int, b: Note, c: Note) -> String:
    return b.text


def main():
    var app = App()
    app.put["/x/{a}"](h)
