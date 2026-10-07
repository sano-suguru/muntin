# Must not compile: two route values on `get` with one placeholder; the
# message names no type. Decision:
# docs/history/architecture-decisions.md, "Several route values decision
# (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes two route values; route must declare exactly two path or query parameters
from muntin import App


def h(a: Int, b: String) -> String:
    return b


def main():
    var app = App()
    app.get["/x/{a}"](h)
