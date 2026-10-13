# Must not compile: a parameterless `post` handler on a route with a
# placeholder, as on `get`.
# Decision: docs/history/architecture-decisions.md, "Bodyless typed post, put
# and patch handlers decision (M3-048)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: route declares a path parameter but the handler takes none
from muntin import App


def h() -> String:
    return "x"


def main():
    var app = App()
    app.post["/x/{id}"](h)
