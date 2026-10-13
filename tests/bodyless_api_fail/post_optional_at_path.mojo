# Must not compile: a bodyless `post` handler's `Optional` value binds a query
# parameter, as on `get`.
# Decision: docs/history/architecture-decisions.md, "Bodyless typed post, put
# and patch handlers decision (M3-048)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one Optional route value; route must declare exactly one query parameter and no path parameter
from muntin import App


def h(n: Optional[Int]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/x/{n}"](h)
