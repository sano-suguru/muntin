# Must not compile: production `post` takes no `Headers` slot before its body,
# on a route with one placeholder. The message is production's existing rule for
# a first slot other than a route value, which M3-016 keeps. Here it guards the
# case the slice's `_post_rule` edit exists for: without it, this shape
# registers and binds the route value as a field name and the body as its value.
# Decision: docs/history/architecture-decisions.md, "Typed get header access
# decision (M3-016)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a post handler's parameter before the body is a route value: an Int, a String or an Optional of either
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
    app.post["/x/{id}"](h)
