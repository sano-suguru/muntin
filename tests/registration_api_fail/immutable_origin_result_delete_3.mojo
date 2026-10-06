# Must not compile: a handler whose result is an immutable-origin `StringSlice`
# other than `StaticString` (here `ImmutAnyOrigin`), registered through
# `App.delete`'s stateless slot-arity-3 overload with a shape that overload
# accepts. Generic `==` cannot tell such a result from `StaticString`, so every
# overload accepts its result only through the `where` clause, which the
# compiler checks by identity at the call site
# (docs/history/architecture-decisions.md, "Registration structure decision
# (M3-014)"; the overload: "Several route values decision (M3-022)").
# Expected diagnostic (checked by scripts/check.sh): identical(R, StringSpan[ImmStaticOrigin])
from muntin import App, Headers


def h(id: Int, name: String, headers: Headers) -> StringSlice[ImmutAnyOrigin]:
    return StringSlice[ImmutAnyOrigin](StaticString("any"))


def main():
    var app = App()
    app.delete["/x/{id}/{name}"](h)
