# Must not compile: `Optional[Float64]` before the body on `post` is a type of
# no kind. Decision: docs/history/architecture-decisions.md, "Optional query
# values decision (M3-024)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a post handler's parameter before the body is a route value: an Int, a String or an Optional of either
from muntin import App, FromBody


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(a: Optional[Float64], body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.post["/x?{a}"](h)
