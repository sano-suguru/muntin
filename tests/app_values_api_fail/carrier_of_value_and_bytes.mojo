# Must not compile: a `WithHeaders` around a type that is both a
# `FromRouteValue` and a `FromBytes`, rejected as the type is bare, as with a
# `FromBody` (carrier_of_value_and_body.mojo). Decision:
# docs/history/architecture-decisions.md, "Application route-value types
# decision (M3-054)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a parameter's type conforms to FromRouteValue and to FromBody or FromBytes; a type is a route value or a body, not both
from muntin import App, FromBytes, FromRouteValue, WithHeaders


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


def h(var b: WithHeaders[Both]) -> String:
    return String(b.body.size)


def main() raises:
    var app = App()
    app.post["/x"](h)
