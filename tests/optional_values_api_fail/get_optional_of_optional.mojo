# Must not compile: `Optional[Optional[Int]]` on `get` is a type of no kind:
# only an `Optional` of `Int` or `String` is a route value. Decision:
# docs/history/architecture-decisions.md, "Optional query values decision
# (M3-024)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler's parameter is an Int or String route value, an Optional of one, the request Headers or, for a raw handler, the Request
from muntin import App


def h(a: Optional[Optional[Int]]) -> String:
    return "x"


def main():
    var app = App()
    app.get["/x?{a}"](h)
