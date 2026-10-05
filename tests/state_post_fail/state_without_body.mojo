# Must not compile: POST has no stateful shape without a body; a handler
# taking only State, registered with its state, selects post's stateful
# parameterless overload, whose rule check requires the body (M3-006, M3-015).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a post handler takes the request body as its last parameter
from muntin import App, FromBody, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


struct Note(FromBody):
    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(db: State[Db]) -> String:
    return String(db[].n)


def main():
    var app = App()
    app.post["/x"](h, State(Db(1)))
