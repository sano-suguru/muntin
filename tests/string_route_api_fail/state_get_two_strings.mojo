# Must not compile: the stateful form of get_int_then_string.mojo, with two
# `String` route values on a route with one placeholder. Decision:
# docs/history/architecture-decisions.md, "Route-value decoding and String
# route values decision (M3-018)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes at most one route value
from muntin import App, State


struct P(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(p: State[P], a: String, b: String) -> String:
    return a + b


def main():
    var app = App()
    app.get["/x/{a}"](h, State(P(1)))
