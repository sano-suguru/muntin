# Must not compile: an `Optional[Int]` and an `Int` before an `Int` in the
# body position on `put`, the optional one at the path placeholder of
# `/x/{a}?{b}`. The path-position rule runs right after the two-value
# placeholder count, before the body rules, so its message wins over `Int is a
# route-value type, never the request body`. Decision:
# docs/history/architecture-decisions.md, "Optional query values decision
# (M3-024)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: an Optional route value binds a query parameter; route values bind the path parameters first, then the query parameters
from muntin import App


def h(a: Optional[Int], b: Int, c: Int) -> String:
    return String(b)


def main():
    var app = App()
    app.put["/x/{a}?{b}"](h)
