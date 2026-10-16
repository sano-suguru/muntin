# Must not compile: a record after a bare route value, in the stateful form
# (delete). Decision: docs/history/architecture-decisions.md, "Route-value
# records decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a handler takes at most one RouteValues record, as its first parameter after any State
from muntin import App, RouteValues, State


@fieldwise_init
struct ProjectAt(RouteValues):
    var project_id: Int


@fieldwise_init
struct Db(Movable):
    var n: Int


def h(db: State[Db], org_id: Int, at: ProjectAt) -> String:
    return ""


def main():
    var app = App()
    app.delete["/o/{org_id}/p/{project_id}"](h, State(Db(1)))
