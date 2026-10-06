# Must not compile: three route values on `get`, whatever the literal
# declares; the message names the method. Decision:
# docs/history/architecture-decisions.md, "Several route values decision
# (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes at most two route values
from muntin import App


def h(a: Int, b: Int, c: Int) -> String:
    return String(a + b + c)


def main():
    var app = App()
    app.get["/x/{a}/{b}/{c}"](h)
