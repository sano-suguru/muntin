# Must not compile: a bodyless patch handler (M3-048) with two Params in the
# other order takes get's rules, the names rule included.
# Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: route value 1 is Param["b"] but binds {a}; route values bind the path parameters left to right, then the query parameters
from muntin import App, Param


def h(b: Param["b", String], a: Param["a", String]) -> String:
    return a.value + b.value


def main():
    var app = App()
    app.patch["/x/{a}/{b}"](h)
