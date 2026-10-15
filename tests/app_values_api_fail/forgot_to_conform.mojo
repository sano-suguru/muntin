# Must not compile: a type with a `from_route_value` that does not declare
# `FromRouteValue` is a parameter of no kind; the message names the trait. Decision:
# docs/history/architecture-decisions.md, "Application route-value types
# decision (M3-054)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler's parameter is an Int or String route value, an Optional of one, a FromRouteValue type, the request Headers or, for a raw handler, the Request
from muntin import App


struct UserId(Movable):
    var value: Int

    def __init__(out self, value: Int):
        self.value = value

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        return Self(Int(value))


def h(id: UserId) -> String:
    return String(id.value)


def main() raises:
    var app = App()
    app.get["/users/{id}"](h)
