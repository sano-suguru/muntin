# Must not compile: a helper generic over the handler's result whose own `where`
# clause is a disjunction that does not prove one branch of the registration's
# clause (`R == String or R == StaticString`) is rejected at its forwarding
# call, even when instantiated with an accepted type: the compiler needs the
# clause proven from the helper's constraints, not from the instantiated type.
# This bounds edge 4 (docs/history/architecture-decisions.md, "Registration
# structure amendment: generic forwarding (M3-015)"); a clause naming one type
# (`where R == StaticString`) or the registration's full clause registers
# (tests/test_registration.mojo).
# Expected diagnostic (checked by scripts/check.sh): invalid call to 'get': lacking evidence to prove correctness
from muntin import App


def static_text() -> StaticString:
    return "static"


def register[
    R: Movable & Deinitable
](mut app: App, h: def() thin raises Never -> R) where (
    R == String or R == StaticString
):
    app.get["/x"](h)


def main():
    var app = App()
    register(app, static_text)
