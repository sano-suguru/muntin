# Must not compile: A `delete` parameter of no kind (`Float64`); the message
# names the method. Decision: docs/history/architecture-decisions.md, "HTTP
# methods decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a delete handler's parameter is an Int or String route value, an Optional of one, the request Headers or, for a raw handler, the Request
from muntin import App


def h(x: Float64) -> String:
    return String(x)


def main():
    var app = App()
    app.delete["/x"](h)
