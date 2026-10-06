# Must not compile: A parameter of no kind (`Float64`) before the body on
# `put`; the message names the method. Decision:
# docs/history/architecture-decisions.md, "HTTP methods decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a put handler's parameter before the body is an Int or String route value
from muntin import App, FromBody


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(x: Float64, body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.put["/x"](h)
