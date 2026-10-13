# Must not compile: a bodyless `post` shape takes `get`'s rules: `Headers` is
# last.
# Decision: docs/history/architecture-decisions.md, "Bodyless typed post, put
# and patch handlers decision (M3-048)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a post handler takes one Headers, as its last parameter
from muntin import App, Headers


def h(headers: Headers, id: Int) -> String:
    return "x"


def main():
    var app = App()
    app.post["/x/{id}"](h)
