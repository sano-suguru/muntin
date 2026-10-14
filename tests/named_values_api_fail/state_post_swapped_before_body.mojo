# Must not compile: the stateful post form, two values before a body in the
# other order. Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: route value 1 is Param["pid"] but binds {uid}; route values bind the path parameters left to right, then the query parameters
from muntin import App, FromBody, Param, State


struct P(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(
    p: State[P], pid: Param["pid", Int], uid: Param["uid", Int], body: Note
) -> String:
    return body.text


def main():
    var app = App()
    app.post["/users/{uid}/posts/{pid}"](h, State(P(1)))
