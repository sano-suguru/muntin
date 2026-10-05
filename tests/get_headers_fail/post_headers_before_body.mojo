# Must not compile: production `post` takes no `Headers` slot before its
# body. The message is production's existing rule for a first slot other
# than a route value, which M3-016 keeps. Decision: docs/ARCHITECTURE.md,
# "Typed get header access decision (M3-016)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a post handler's parameter before the body is an Int route value
from muntin import App, FromBody, Headers


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(headers: Headers, body: Note) -> String:
    return "x"


def main():
    var app = App()
    app.post["/x"](h)
