# Must not compile: a stateful body-only POST handler registered without its
# state (M3-006) selects post's stateless two-slot overload, whose rule check
# reports the State rule (M3-015).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: State is injected application state, not the request body; a stateful post handler takes State first and the body last, and the state is the registration's second argument
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


def h(db: State[Db], body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.post["/x"](h)
