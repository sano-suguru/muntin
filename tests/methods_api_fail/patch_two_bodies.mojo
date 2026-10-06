# Must not compile: `patch` takes `post`'s shapes, so one body, last; the
# message names the method. Decision: docs/history/architecture-decisions.md,
# "HTTP methods decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a patch handler takes one request body, as its last parameter
from muntin import App, FromBody


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(a: Note, b: Note) -> String:
    return a.text + b.text


def main():
    var app = App()
    app.patch["/x"](h)
