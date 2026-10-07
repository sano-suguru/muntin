# Must not compile: two values on `get`, the `Optional[Int]` first, so it
# would bind the path placeholder of `/x/{a}?{b}` (a required-optional swap).
# Decision: docs/history/architecture-decisions.md, "Optional query values
# decision (M3-024)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: an Optional route value binds a query parameter; route values bind the path parameters first, then the query parameters
from muntin import App


def h(limit: Optional[Int], uid: Int) -> String:
    return String(uid)


def main():
    var app = App()
    app.get["/x/{a}?{b}"](h)
