# Must not compile: the stateful form of get_string_without_placeholder.mojo; a
# leading `State[S]` does not change the placeholder rule for a `String`.
# Decision:
# docs/history/architecture-decisions.md, "Route-value decoding and String
# route values decision (M3-018)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one String parameter; route must declare exactly one path or query parameter
from muntin import App, State


struct P(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(p: State[P], name: String) -> String:
    return name


def main():
    var app = App()
    app.get["/x"](h, State(P(1)))
