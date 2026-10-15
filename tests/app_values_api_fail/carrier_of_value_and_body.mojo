# Must not compile: a `WithHeaders` around a type that is both a
# `FromRouteValue` and a `FromBody` passes the carrier's bound through
# `FromBody`, and is rejected as the type is bare, so the carrier picks no
# conversion silently. Decision:
# docs/history/architecture-decisions.md, "Application route-value types
# decision (M3-054)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a parameter's type conforms to FromRouteValue and to FromBody or FromBytes; a type is a route value or a body, not both
from muntin import App, FromBody, FromRouteValue, WithHeaders


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


def h(var b: WithHeaders[Both]) -> String:
    return b.body.text


def main() raises:
    var app = App()
    app.post["/x"](h)
