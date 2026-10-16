# Must not compile: a field whose type is both a FromRouteValue and a
# FromBytes, in the stateful form (get); the message names the field.
# Decision: docs/history/architecture-decisions.md, "Route-value records
# decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field 1 of the RouteValues record, blob, conforms to FromRouteValue and to FromBody or FromBytes; a type is a route value or a body, not both
from muntin import App, FromBytes, FromRouteValue, RouteValues, State


@fieldwise_init
struct Both(FromBytes, FromRouteValue):
    comptime max_bytes = 8
    var size: Int

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        return Self(value.byte_length())

    @staticmethod
    def from_bytes(bytes: List[UInt8]) raises -> Self:
        return Self(len(bytes))


@fieldwise_init
struct BlobAt(RouteValues):
    var blob: Both
    var id: Int


@fieldwise_init
struct Db(Movable):
    var n: Int


def h(db: State[Db], at: BlobAt) -> String:
    return ""


def main():
    var app = App()
    app.get["/b/{blob}/{id}"](h, State(Db(1)))
