# Must not compile: a Param around a Param is a slot of no kind. Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler's parameter is an Int or String route value, an Optional of one, the request Headers or, for a raw handler, the Request
from muntin import App, Param


def h(x: Param["x", Param["x", Int]]) -> String:
    return String(x.value.value)


def main():
    var app = App()
    app.get["/x/{x}"](h)
