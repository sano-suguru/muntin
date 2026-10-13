# Must not compile: a last parameter of no kind on `put` is still read as a
# body whose type forgot its conformance, not as a bodyless shape.
# Decision: docs/history/architecture-decisions.md, "Bodyless typed post, put
# and patch handlers decision (M3-048)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's last parameter is the request body; its type must conform to FromBody or FromBytes
from muntin import App


struct Form(Movable):
    var name: String


def h(id: Int, form: Form) -> String:
    return "x"


def main():
    var app = App()
    app.put["/x/{id}"](h)
