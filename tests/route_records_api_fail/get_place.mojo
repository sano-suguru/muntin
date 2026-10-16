# Must not compile: a record after a bare route value (get). Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a handler takes at most one RouteValues record, as its first parameter after any State
from muntin import App, RouteValues


@fieldwise_init
struct ProjectAt(RouteValues):
    var project_id: Int


def h(org_id: Int, at: ProjectAt) -> String:
    return ""


def main():
    var app = App()
    app.get["/o/{org_id}/p/{project_id}"](h)
