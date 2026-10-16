# Must not compile: a field that is not a route value, in the stateful form
# (delete). Decision: docs/history/architecture-decisions.md, "Route-value
# records decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field 2 of the RouteValues record, ratio, is not a bare route value: a field is an Int, a String, an Optional of either or a FromRouteValue type, never a Param or a record
from muntin import App, RouteValues, State


@fieldwise_init
struct Odd(RouteValues):
    var org_id: Int
    var ratio: Float64


@fieldwise_init
struct Db(Movable):
    var n: Int


def h(db: State[Db], at: Odd) -> String:
    return ""


def main():
    var app = App()
    app.delete["/o/{org_id}/r/{ratio}"](h, State(Db(1)))
