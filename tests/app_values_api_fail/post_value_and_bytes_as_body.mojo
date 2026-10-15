# Must not compile: a type that is both a `FromRouteValue` and a `FromBytes`
# in post's body position, where it would otherwise be taken as the body.
# Decision:
# docs/history/architecture-decisions.md, "Application route-value types
# decision (M3-054)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a parameter's type conforms to FromRouteValue and to FromBody or FromBytes; a type is a route value or a body, not both
from muntin import App, FromBytes, FromRouteValue


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


def h(b: Both) -> String:
    return String(b.size)


def main() raises:
    var app = App()
    app.post["/x"](h)
