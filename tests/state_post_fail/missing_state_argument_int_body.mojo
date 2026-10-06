# Must not compile: a stateful route-value-then-body POST handler registered
# without its state (M3-006). Its three request parameters select `post`'s
# stateless slot-arity-3 overload, so the `State` in a slot is reported by its
# rule, where before slot arity 3 no overload matched and the compiler said
# `missing required argument: 'state'`. Decision:
# docs/history/architecture-decisions.md, "Several route values decision
# (M3-022)".
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


def h(db: State[Db], id: Int, body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.post["/x/{id}"](h)
