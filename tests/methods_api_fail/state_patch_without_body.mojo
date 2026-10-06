# Must not compile: A stateful `patch` handler with no body, its state passed:
# the stateful zero-slot overload reports the body rule with the method's name.
# Decision: docs/history/architecture-decisions.md, "HTTP methods decision
# (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a patch handler takes the request body as its last parameter
from muntin import App, State


struct P(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(p: State[P]) -> String:
    return "x"


def main():
    var app = App()
    app.patch["/x"](h, State(P(1)))
