# Must not compile: Two `Int` route values on `delete`; the message names the
# method. Decision: docs/history/architecture-decisions.md, "HTTP methods
# decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a delete handler takes at most one Int route value
from muntin import App


def h(a: Int, b: Int) -> String:
    return String(a + b)


def main():
    var app = App()
    app.delete["/x/{a}/{b}"](h)
