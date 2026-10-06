# Must not compile: `delete` takes `get`'s shapes, so a typed `delete` handler
# takes no request body (a raw handler reads one); the message names the
# method. Decision: docs/history/architecture-decisions.md, "HTTP methods
# decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a delete handler takes no request body
from muntin import App, FromBody


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.delete["/x"](h)
