# Must not compile: the stateful `delete` form, one `Optional[String]` and
# `Headers`, on a literal with two query placeholders. Decision:
# docs/history/architecture-decisions.md, "Optional query values decision
# (M3-024)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one Optional route value; route must declare exactly one query parameter and no path parameter
from muntin import App, Headers, State


struct P(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(p: State[P], a: Optional[String], headers: Headers) -> String:
    return a.or_else("")


def main():
    var app = App()
    app.delete["/x?{a}&{b}"](h, State(P(1)))
