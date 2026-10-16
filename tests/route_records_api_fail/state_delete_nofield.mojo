# Must not compile: a record with no field, in the stateful form (delete).
# Decision: docs/history/architecture-decisions.md, "Route-value records
# decision (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the RouteValues record has no field; a record has one field per path or query parameter
from muntin import App, RouteValues, State


struct Empty(RouteValues):
    def __init__(out self):
        pass


@fieldwise_init
struct Db(Movable):
    var n: Int


def h(db: State[Db], at: Empty) -> String:
    return ""


def main():
    var app = App()
    app.delete["/x"](h, State(Db(1)))
