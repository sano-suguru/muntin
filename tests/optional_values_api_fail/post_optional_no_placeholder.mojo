# Must not compile: one `Optional[Int]` and a body on `post` whose literal
# declares no placeholder. Decision: docs/history/architecture-decisions.md,
# "Optional query values decision (M3-024)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one Optional route value and the request body; route must declare exactly one query parameter and no path parameter
from muntin import App, FromBody


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(a: Optional[Int], body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.post["/x"](h)
