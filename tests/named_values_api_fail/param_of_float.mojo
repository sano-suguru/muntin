# Must not compile: a Param's value type is a route value's type (Int,
# String or an Optional of either); any other is a slot of no kind. Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler's parameter is an Int or String route value, an Optional of one, a FromRouteValue type, the request Headers or, for a raw handler, the Request
from muntin import App, Param


def h(x: Param["x", Float64]) -> String:
    return String(x.value)


def main():
    var app = App()
    app.get["/x/{x}"](h)
