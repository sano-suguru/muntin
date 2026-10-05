# Must not compile: a handler whose result is an immutable-origin
# `StringSlice` other than `StaticString` (here `ImmutAnyOrigin`), registered
# through `App.get`'s stateful slot-arity-0 overload with a shape that
# overload accepts. Generic `==` cannot tell such a result from
# `StaticString`, so every overload accepts its result only through the
# `where` clause, which the compiler checks by identity at the call site
# (docs/ARCHITECTURE.md, "Registration structure decision (M3-014)").
# Expected diagnostic (checked by scripts/check.sh): identical(R, StringSpan[ImmStaticOrigin])
from muntin import App, State


@fieldwise_init
struct Db(Movable):
    var name: String


def h(db: State[Db]) -> StringSlice[ImmutAnyOrigin]:
    return StringSlice[ImmutAnyOrigin](StaticString("any"))


def main():
    var app = App()
    app.get["/x"](h, State(Db("db")))
