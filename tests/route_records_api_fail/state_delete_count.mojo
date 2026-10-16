# Must not compile: more fields than placeholders, in the stateful form
# (delete). Decision: docs/history/architecture-decisions.md, "Route-value
# records decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the RouteValues record has 3 fields but the route declares 2 path and query parameters; a record has one field per parameter
from muntin import App, RouteValues, State


@fieldwise_init
struct TaskAt(RouteValues):
    var org_id: Int
    var project_id: Int
    var task_id: Int


@fieldwise_init
struct Db(Movable):
    var n: Int


def h(db: State[Db], at: TaskAt) -> String:
    return ""


def main():
    var app = App()
    app.delete["/o/{org_id}/p/{project_id}"](h, State(Db(1)))
