# Must not compile: one `Optional[Int]` and an `Int` in the body position on
# `post` whose literal declares no placeholder. The one-value placeholder rule
# runs before the body rules, so the optional value's message wins over `Int
# is a route-value type, never the request body`. Decision:
# docs/history/architecture-decisions.md, "Optional query values decision
# (M3-024)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one Optional route value and the request body; route must declare exactly one query parameter and no path parameter
from muntin import App


def h(a: Optional[Int], b: Int) -> String:
    return String(b)


def main():
    var app = App()
    app.post["/x"](h)
