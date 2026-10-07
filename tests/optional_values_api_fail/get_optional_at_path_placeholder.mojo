# Must not compile: one `Optional[Int]` on `get` whose literal declares a path
# placeholder: a path segment is never absent. Decision:
# docs/history/architecture-decisions.md, "Optional query values decision
# (M3-024)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one Optional route value; route must declare exactly one query parameter and no path parameter
from muntin import App


def h(a: Optional[Int]) -> String:
    return String(a.or_else(0))


def main():
    var app = App()
    app.get["/x/{a}"](h)
