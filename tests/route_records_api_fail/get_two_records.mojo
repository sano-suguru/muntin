# Must not compile: two records (get). Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a handler takes at most one RouteValues record, as its first parameter after any State
from muntin import App, RouteValues


@fieldwise_init
struct OrgAt(RouteValues):
    var org_id: Int


@fieldwise_init
struct ProjectAt(RouteValues):
    var project_id: Int


def h(org: OrgAt, at: ProjectAt) -> String:
    return ""


def main():
    var app = App()
    app.get["/o/{org_id}/p/{project_id}"](h)
