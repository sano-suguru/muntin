# Must not compile: a type that is both a `FromRouteValue` and a `FromBytes`,
# before a body on put. Decision:
# docs/history/architecture-decisions.md, "Application route-value types
# decision (M3-054)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a parameter's type conforms to FromRouteValue and to FromBody or FromBytes; a type is a route value or a body, not both
from muntin import App, FromBody, FromBytes, FromRouteValue


struct Both(FromBytes, FromRouteValue, Movable):
    comptime max_bytes = 16
    var size: Int

    def __init__(out self, size: Int):
        self.size = size

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(len(body))

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        return Self(value.byte_length())


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(b: Both, var n: Note) -> String:
    return n.text


def main() raises:
    var app = App()
    app.put["/x/{b}"](h)
