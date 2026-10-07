# Must not compile: two `String` route values on a stateful `get` with one
# placeholder; two values need exactly two, whatever their types. Decisions:
# docs/history/architecture-decisions.md, "Route-value decoding and String
# route values decision (M3-018)" and "Several route values decision (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes two route values; route must declare exactly two path or query parameters
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
