# Must not compile: an Optional field at a path placeholder, in the stateful
# form (delete). Decision: docs/history/architecture-decisions.md,
# "Route-value records decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field 1 of the RouteValues record, org_id, is an Optional but binds the path parameter {org_id}; an Optional field binds a query parameter
from muntin import App, RouteValues, State


@fieldwise_init
struct OptPath(RouteValues):
    var org_id: Optional[Int]


@fieldwise_init
struct Db(Movable):
    var n: Int


def h(db: State[Db], at: OptPath) -> String:
    return ""


def main():
    var app = App()
    app.delete["/o/{org_id}"](h, State(Db(1)))
