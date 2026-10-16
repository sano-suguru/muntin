# Must not compile: a bare route value after a record (get). Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a handler that takes a RouteValues record takes no other route value; the record has a field for each
from muntin import App, RouteValues


@fieldwise_init
struct OrgAt(RouteValues):
    var org_id: Int


def h(at: OrgAt, project_id: Int) -> String:
    return ""


def main():
    var app = App()
    app.get["/o/{org_id}/p/{project_id}"](h)
