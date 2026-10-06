# Must not compile: a post handler's `String` route value before the body needs
# exactly one path or query placeholder, as an `Int` does. The inverse,
# `def(String, B)` on `/x/{a}`, registers (tests/test_string_route_values.mojo).
# Decision:
# docs/history/architecture-decisions.md, "Route-value decoding and String
# route values decision (M3-018)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one String parameter and the request body; route must declare exactly one path or query parameter
from muntin import App, FromBody


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(name: String, body: Note) -> String:
    return name


def main():
    var app = App()
    app.post["/x"](h)
