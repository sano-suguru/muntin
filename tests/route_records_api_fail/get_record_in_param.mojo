# Must not compile: a record in a Param (get). Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler's parameter is an Int or String route value
from muntin import App, Param, RouteValues


@fieldwise_init
struct OrgAt(RouteValues):
    var org_id: Int


def h(at: Param["org_id", OrgAt]) -> String:
    return ""


def main():
    var app = App()
    app.get["/o/{org_id}"](h)
