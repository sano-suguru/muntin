# Must not compile: the stateful get form of get_mixed_values.mojo, with the
# second value the Param; the State parameter is not a route value.
# Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes two route values and only one is a Param; declare both as Param, each named after the placeholder it binds, or neither
from muntin import App, Param, State


struct P(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(p: State[P], uid: Int, pid: Param["pid", Int]) -> String:
    return String(uid + pid.value)


def main():
    var app = App()
    app.get["/users/{uid}/posts/{pid}"](h, State(P(1)))
