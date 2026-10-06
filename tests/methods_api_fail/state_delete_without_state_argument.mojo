# Must not compile: A stateful `delete` handler registered without its state;
# the message names the method. Decision:
# docs/history/architecture-decisions.md, "HTTP methods decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: State is injected application state; a stateful delete handler takes State first, and the state is the registration's second argument
from muntin import App, State


struct P(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(p: State[P]) -> String:
    return "x"


def main():
    var app = App()
    app.delete["/x"](h)
