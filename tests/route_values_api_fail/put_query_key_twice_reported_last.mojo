# Must not compile: a repeated query key on a shape that also breaks a body
# rule reports the body rule: the distinct-query-keys rule runs only for a
# shape every other rule accepts, so no existing message changes. Decision:
# docs/history/architecture-decisions.md, "Several route values decision
# (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: Int is a route-value type, never the request body; the body parameter's type must conform to FromBody or FromBytes
from muntin import App


def h(a: String, b: String, c: Int) -> String:
    return a + b


def main():
    var app = App()
    app.put["/x?{a}&{a}"](h)
