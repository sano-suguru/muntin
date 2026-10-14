# Must not compile: the stateful get form of get_two_plain_values.mojo; the
# State parameter is not a route value, so the two after it need names.
# Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes two route values; each is a Param named after the placeholder it binds, as Param["name", Int]
from muntin import App, State


struct P(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(p: State[P], uid: Int, pid: Int) -> String:
    return String(uid + pid)


def main():
    var app = App()
    app.get["/users/{uid}/posts/{pid}"](h, State(P(1)))
