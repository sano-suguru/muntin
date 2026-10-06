# Must not compile: two route values and a body on `post` with three
# placeholders, one path and two query. Decision:
# docs/history/architecture-decisions.md, "Several route values decision
# (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes two route values and the request body; route must declare exactly two path or query parameters
from muntin import App, FromBody


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(a: Int, b: String, body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.post["/x/{a}?{b}&{c}"](h)
