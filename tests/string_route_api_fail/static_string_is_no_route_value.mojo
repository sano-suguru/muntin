# Must not compile: the `String` kind is exact type equality, so
# `StaticString` (and `StringSlice`, and application types) is no route
# value; it is a parameter of no kind. Decision:
# docs/history/architecture-decisions.md, "Route-value decoding and String
# route values decision (M3-018)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler's parameter is an Int or String route value, an Optional of one, the request Headers or, for a raw handler, the Request
from muntin import App


def h(name: StaticString) -> String:
    return String(name)


def main():
    var app = App()
    app.get["/x/{a}"](h)
