# Must not compile: a handler whose result is an immutable-origin
# `StringSlice` other than `StaticString` (here `ImmutAnyOrigin`), registered
# through `App.post`'s stateless slot-arity-0 overload with no body, which
# `post` rejects for any result: without the clause the rule check would
# report the shape instead. Generic `==` cannot tell such a result from
# `StaticString`, so every overload accepts its result only through the
# `where` clause, which the compiler checks by identity at the call site
# (docs/ARCHITECTURE.md, "Registration structure decision (M3-014)").
# Expected diagnostic (checked by scripts/check.sh): identical(R, StringSpan[ImmStaticOrigin])
from muntin import App


def h() -> StringSlice[ImmutAnyOrigin]:
    return StringSlice[ImmutAnyOrigin](StaticString("any"))


def main():
    var app = App()
    app.post["/x"](h)
