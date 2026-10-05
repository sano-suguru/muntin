# Must not compile: a helper generic over the handler's result with no
# `where` clause of its own is rejected at its forwarding call: the compiler
# cannot prove the registration's result clause from the helper's
# constraints, even when the helper is instantiated with an accepted type.
# With generic_result_disjunction_lacks_evidence.mojo (a partial
# disjunction), this pins the failing side of edge 4's boundary
# (docs/ARCHITECTURE.md, "Registration structure amendment: generic
# forwarding (M3-015)"); one branch or the whole clause registers
# (tests/test_registration.mojo). On `main` this was `no matching method in
# call to 'get'`.
# Expected diagnostic (checked by scripts/check.sh): invalid call to 'get': lacking evidence to prove correctness
from muntin import App


def text() -> String:
    return "text"


def register[
    R: Movable & Deinitable
](mut app: App, h: def() thin raises Never -> R):
    app.get["/x"](h)


def main():
    var app = App()
    register(app, text)
