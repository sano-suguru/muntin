# Must not compile: a bodyless shape takes at most two route values, and the
# message names the method.
# Decision: docs/history/architecture-decisions.md, "Bodyless typed post, put
# and patch handlers decision (M3-048)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a patch handler takes at most two route values
from muntin import App


def h(a: Int, b: Int, c: Int) -> String:
    return "x"


def main():
    var app = App()
    app.patch["/x/{a}/{b}/{c}"](h)
