# Must not compile: a lone parameter of no kind on `patch` is still read as a
# body whose type forgot its conformance.
# Decision: docs/history/architecture-decisions.md, "Bodyless typed post, put
# and patch handlers decision (M3-048)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's parameter is the request body; its type must conform to FromBody or FromBytes
from muntin import App


struct Form(Movable):
    var name: String


def h(form: Form) -> String:
    return "x"


def main():
    var app = App()
    app.patch["/x"](h)
