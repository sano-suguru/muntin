# Must not compile: a Param around a record that is also a FromRouteValue
# (get). Decision: docs/history/architecture-decisions.md, "Route-value
# records decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a parameter's type conforms to RouteValues and to FromRouteValue, FromBody or FromBytes; a route-value record is none of them
from muntin import App, FromRouteValue, Param, RouteValues


@fieldwise_init
struct OrgValue(FromRouteValue, RouteValues):
    var org_id: Int

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        return Self(Int(value))


def h(at: Param["org_id", OrgValue]) -> String:
    return ""


def main():
    var app = App()
    app.get["/o/{org_id}"](h)
