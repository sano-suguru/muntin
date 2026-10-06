# Must not compile: production `post` takes no `Headers` slot after its body.
# The message is production's existing body-last rule, which M3-016 keeps.
# Decision: docs/history/architecture-decisions.md, "Typed get header access
# decision (M3-016)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a post handler takes one request body, as its last parameter
from muntin import App, FromBody, Headers


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(body: Note, headers: Headers) -> String:
    return "x"


def main():
    var app = App()
    app.post["/x"](h)
