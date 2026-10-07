# Must not compile: two values on `get` over two path placeholders, the second
# one an `Optional[Int]`. Decision: docs/history/architecture-decisions.md,
# "Optional query values decision (M3-024)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: an Optional route value binds a query parameter; route values bind the path parameters first, then the query parameters
from muntin import App


def h(a: Int, b: Optional[Int]) -> String:
    return String(a)


def main():
    var app = App()
    app.get["/x/{a}/{b}"](h)
