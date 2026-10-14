# Must not compile: two route values before a body, only the first a Param.
# Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes two route values and only one is a Param; declare both as Param, each named after the placeholder it binds, or neither
from muntin import App, FromBody, Param


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(id: Param["id", Int], tag: String, body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.post["/u/{id}?{tag}"](h)
