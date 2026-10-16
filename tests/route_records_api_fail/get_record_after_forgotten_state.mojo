# Must not compile: a stateful `get` handler taking a record, registered
# without its state, so its `State` sits in a request slot; the State
# message, not the record's place, names the fault. Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: State is injected application state; a stateful get handler takes State first, and the state is the registration's second argument
from muntin import App, RouteValues, State


@fieldwise_init
struct ProjectAt(RouteValues):
    var org_id: Int
    var project_id: Int


@fieldwise_init
struct Db(Movable):
    var n: Int


def h(db: State[Db], at: ProjectAt) -> String:
    return ""


def main():
    var app = App()
    app.get["/o/{org_id}/p/{project_id}"](h)
