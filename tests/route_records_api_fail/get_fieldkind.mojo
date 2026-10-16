# Must not compile: a field that is not a route value (get). Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field 2 of the RouteValues record, ratio, is not a bare route value: a field is an Int, a String, an Optional of either or a FromRouteValue type, never a Param or a record
from muntin import App, RouteValues


@fieldwise_init
struct Odd(RouteValues):
    var org_id: Int
    var ratio: Float64


def h(at: Odd) -> String:
    return ""


def main():
    var app = App()
    app.get["/o/{org_id}/r/{ratio}"](h)
