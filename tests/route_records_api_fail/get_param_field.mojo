# Must not compile: a field that is a Param (get). Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field 1 of the RouteValues record, org_id, is not a bare route value: a field is an Int, a String, an Optional of either or a FromRouteValue type, never a Param or a record
from muntin import App, Param, RouteValues


@fieldwise_init
struct ParamField(RouteValues):
    var org_id: Param["org_id", Int]


def h(at: ParamField) -> String:
    return ""


def main():
    var app = App()
    app.get["/o/{org_id}"](h)
