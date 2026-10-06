# Must not compile: two route values on `post` with one placeholder and a last
# slot that is no body: the placeholder count is reported before the last
# slot's body rules, as at slot arity 2. Decision:
# docs/history/architecture-decisions.md, "Several route values decision
# (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes two route values and the request body; route must declare exactly two path or query parameters
from muntin import App


def h(a: Int, b: Int, c: Int) -> String:
    return String(a + b + c)


def main():
    var app = App()
    app.post["/x/{a}"](h)
