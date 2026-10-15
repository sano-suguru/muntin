# Must not compile: `Optional` of an application value is no route value:
# only `Optional[Int]` and `Optional[String]` are optional values. Decision:
# docs/history/architecture-decisions.md, "Application route-value types
# decision (M3-054)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler's parameter is an Int or String route value, an Optional of one, a FromRouteValue type, the request Headers or, for a raw handler, the Request
from muntin import App, FromRouteValue


struct UserId(FromRouteValue, Movable):
    var value: Int

    def __init__(out self, value: Int):
        self.value = value

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        return Self(Int(value))


def h(id: Optional[UserId]) -> String:
    return "x"


def main() raises:
    var app = App()
    app.get["/users?{id}"](h)
