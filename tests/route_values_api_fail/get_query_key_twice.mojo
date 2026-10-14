# Must not compile: the `get` form of put_query_key_twice.mojo, through
# the two-slot overload. Decision:
# docs/history/architecture-decisions.md, "Several route values decision
# (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: route declares a query parameter twice
from muntin import App


def h(a: String, b: String) -> String:
    return a + b


def main():
    var app = App()
    app.get["/x?{a}&{a}"](h)
