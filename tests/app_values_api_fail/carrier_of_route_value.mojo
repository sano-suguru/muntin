# Must not compile: a `FromRouteValue` type is no body, so a `WithHeaders`
# around one is rejected where the handler declares it. Decision:
# docs/history/architecture-decisions.md, "Application route-value types
# decision (M3-054)".
# Expected diagnostic (checked by scripts/check.sh): 'WithHeaders' parameter 'B' has '_FromBodyOrBytes' type, but value has type 'AnyStruct[UserId]'
from muntin import App, FromRouteValue, WithHeaders


struct UserId(FromRouteValue, Movable):
    var value: Int

    def __init__(out self, value: Int):
        self.value = value

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        return Self(Int(value))


def h(b: WithHeaders[UserId]) -> String:
    return "x"


def main() raises:
    var app = App()
    app.post["/x"](h)
