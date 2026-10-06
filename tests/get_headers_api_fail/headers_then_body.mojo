# Must not compile: the `Headers` rule runs after the `State`, `Request`, body
# and no-kind rules, so a body beside a `Headers` slot keeps the `get` body
# message it had before `Headers` was a slot kind. Decision:
# docs/history/architecture-decisions.md, "Typed get header access decision
# (M3-016)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes no request body
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
    app.get["/x"](h)
