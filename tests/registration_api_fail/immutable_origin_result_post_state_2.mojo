# Must not compile: a handler whose result is an immutable-origin `StringSlice`
# other than `StaticString` (here `ImmutAnyOrigin`), registered through
# `App.post`'s stateful slot-arity-2 overload with a shape that overload
# accepts. Generic `==` cannot tell such a result from `StaticString`, so every
# overload accepts its result only through the `where` clause, which the
# compiler checks by identity at the call site
# (docs/history/architecture-decisions.md, "Registration structure decision
# (M3-014)").
# Expected diagnostic (checked by scripts/check.sh): identical(R, StringSpan[ImmStaticOrigin])
from muntin import App, FromBody, State


struct Note(FromBody):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


@fieldwise_init
struct Db(Movable):
    var name: String


def h(db: State[Db], id: Int, body: Note) -> StringSlice[ImmutAnyOrigin]:
    return StringSlice[ImmutAnyOrigin](StaticString("any"))


def main():
    var app = App()
    app.post["/x/{id}"](h, State(Db("db")))
