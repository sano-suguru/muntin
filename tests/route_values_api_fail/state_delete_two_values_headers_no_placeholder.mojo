# Must not compile: the stateful `delete` form, two route values and
# `Headers` on a route with no placeholder. Decision:
# docs/history/architecture-decisions.md, "Several route values decision
# (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes two route values; route must declare exactly two path or query parameters
from muntin import App, Headers, State


struct P(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(p: State[P], a: Int, b: Int, headers: Headers) -> String:
    return String(a + b)


def main():
    var app = App()
    app.delete["/x"](h, State(P(1)))
