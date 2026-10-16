# Must not compile: a field whose type is both a FromRouteValue and a
# FromBody (put). Decision: docs/history/architecture-decisions.md,
# "Route-value records decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field 2 of the RouteValues record, both, conforms to FromRouteValue and to FromBody or FromBytes; a type is a route value or a body, not both
from muntin import App, FromBody, FromRouteValue, RouteValues


@fieldwise_init
struct Both(FromBody, FromRouteValue):
    var text: String

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        return Self(value)

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


@fieldwise_init
struct BothField(RouteValues):
    var org_id: Int
    var both: Both


def h(at: BothField) -> String:
    return ""


def main():
    var app = App()
    app.put["/o/{org_id}/b/{both}"](h)
