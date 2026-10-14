# Must not compile: a bodyless patch handler (M3-048) with two unnamed
# values takes get's rules, the names rule included. Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes two route values; each is a Param named after the placeholder it binds, as Param["name", Int]
from muntin import App


def h(a: String, b: String) -> String:
    return a + b


def main():
    var app = App()
    app.patch["/x/{a}/{b}"](h)
