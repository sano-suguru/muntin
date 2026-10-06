# Must not compile: the stateful `delete` form of get_three_values.mojo, on a
# literal with two placeholders: three values are reported before the count.
# Decision: docs/history/architecture-decisions.md, "Several route values
# decision (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a delete handler takes at most two route values
from muntin import App, State


struct P(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(p: State[P], a: String, b: Int, c: String) -> String:
    return a + c


def main():
    var app = App()
    app.delete["/x/{a}?{c}"](h, State(P(1)))
