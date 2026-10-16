# Must not compile: a placeholder named twice, in the stateful form (delete).
# Decision: docs/history/architecture-decisions.md, "Route-value records
# decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the route declares the parameter {id} twice; a RouteValues record binds each parameter to the field of its name
from muntin import App, RouteValues, State


@fieldwise_init
struct Twice(RouteValues):
    var id: Int
    var other: Int


@fieldwise_init
struct Db(Movable):
    var n: Int


def h(db: State[Db], at: Twice) -> String:
    return ""


def main():
    var app = App()
    app.delete["/a/{id}/b/{id}"](h, State(Db(1)))
