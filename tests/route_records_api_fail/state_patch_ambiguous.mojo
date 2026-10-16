# Must not compile: a record that is also a FromRouteValue, in the stateful
# form, before a body (patch). Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a parameter's type conforms to RouteValues and to FromRouteValue, FromBody or FromBytes; a route-value record is none of them
from muntin import App, FromBody, FromRouteValue, RouteValues, State


@fieldwise_init
struct OrgValue(FromRouteValue, RouteValues):
    var org_id: Int

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        return Self(Int(value))


@fieldwise_init
struct Db(Movable):
    var n: Int


@fieldwise_init
struct Note(FromBody):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(db: State[Db], at: OrgValue, body: Note) -> String:
    return ""


def main():
    var app = App()
    app.patch["/o/{org_id}"](h, State(Db(1)))
