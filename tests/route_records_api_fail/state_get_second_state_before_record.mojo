# Must not compile: a stateful `get` handler with a second `State` before
# its record; the State message, not the record's place, names the fault.
# Decision: docs/history/architecture-decisions.md, "Route-value records
# decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a handler takes at most one State, as its first parameter
from muntin import App, RouteValues, State


@fieldwise_init
struct ProjectAt(RouteValues):
    var org_id: Int
    var project_id: Int


@fieldwise_init
struct Db(Movable):
    var n: Int


def h(db: State[Db], other: State[Db], at: ProjectAt) -> String:
    return ""


def main():
    var app = App()
    app.get["/o/{org_id}/p/{project_id}"](h, State(Db(1)))
