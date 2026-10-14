# Must not compile: the stateful delete form, the second value (a query
# value) misnamed. Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: route value 2 is Param["lim"] but binds {limit}; route values bind the path parameters left to right, then the query parameters
from muntin import App, Param, State


struct P(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(
    p: State[P], id: Param["id", Int], lim: Param["lim", Optional[Int]]
) -> String:
    return String(id.value)


def main():
    var app = App()
    app.delete["/u/{id}?{limit}"](h, State(P(1)))
