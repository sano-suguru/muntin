# Must not compile: a handler taking only State registered on POST without a
# state. State is injected application state, never the request body
# (M3-006); the body overload's guard names it before FromBody.
# Expected diagnostic (checked by scripts/check.sh): State is injected application state, not the request body; a stateful post handler takes State first and the body last, and the state is the registration's second argument
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
    app.post["/x"](h)
