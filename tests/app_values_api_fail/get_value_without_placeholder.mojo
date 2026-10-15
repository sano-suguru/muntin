# Must not compile: one application value on a literal with no placeholder. Decision:
# docs/history/architecture-decisions.md, "Application route-value types
# decision (M3-054)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one route value; route must declare exactly one path or query parameter
from muntin import App, FromRouteValue


struct UserId(FromRouteValue, Movable):
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
    app.get["/users"](h)
