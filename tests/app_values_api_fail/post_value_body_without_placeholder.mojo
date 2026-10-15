# Must not compile: one application value and a body on a literal with two
# placeholders. Decision:
# docs/history/architecture-decisions.md, "Application route-value types
# decision (M3-054)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one route value and the request body; route must declare exactly one path or query parameter
from muntin import App, FromBody, FromRouteValue


struct UserId(FromRouteValue, Movable):
    var value: Int

    def __init__(out self, value: Int):
        self.value = value

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        return Self(Int(value))


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(id: UserId, var n: Note) -> String:
    return n.text


def main() raises:
    var app = App()
    app.post["/users/{id}/{x}"](h)
