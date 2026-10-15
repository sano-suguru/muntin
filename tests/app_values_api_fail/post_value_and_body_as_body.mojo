# Must not compile: the same type in post's body position, where it would
# otherwise be taken as the body. Decision:
# docs/history/architecture-decisions.md, "Application route-value types
# decision (M3-054)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a parameter's type conforms to FromRouteValue and to FromBody or FromBytes; a type is a route value or a body, not both
from muntin import App, FromBody, FromRouteValue


struct Both(FromBody, FromRouteValue, Movable):
    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        return Self(value)


def h(b: Both) -> String:
    return b.text


def main() raises:
    var app = App()
    app.post["/x"](h)
