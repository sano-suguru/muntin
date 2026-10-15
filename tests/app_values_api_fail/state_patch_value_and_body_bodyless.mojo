# Must not compile: the ambiguous type as the one value of a stateful,
# otherwise bodyless patch handler. Decision:
# docs/history/architecture-decisions.md, "Application route-value types
# decision (M3-054)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a parameter's type conforms to FromRouteValue and to FromBody or FromBytes; a type is a route value or a body, not both
from muntin import App, FromBody, FromRouteValue, State


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


def h(s: State[Int], b: Both) -> String:
    return b.text


def main() raises:
    var app = App()
    app.patch["/x/{b}"](h, State(1))
