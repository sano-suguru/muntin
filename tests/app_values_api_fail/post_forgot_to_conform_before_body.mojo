# Must not compile: the same before a body on post. Decision:
# docs/history/architecture-decisions.md, "Application route-value types
# decision (M3-054)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a post handler's parameter before the body is a route value: an Int, a String, an Optional of either or a FromRouteValue type
from muntin import App, FromBody


struct UserId(Movable):
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
    app.post["/users/{id}"](h)
