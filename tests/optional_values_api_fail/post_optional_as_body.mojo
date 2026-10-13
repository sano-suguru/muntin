# Must not compile: `Optional[Int]` as `post`'s only parameter is a route
# value, never a body, so the handler is bodyless and its optional value needs
# one query placeholder (M3-024, M3-048).
# Decision: docs/history/architecture-decisions.md, "Bodyless typed post,
# put and patch handlers decision (M3-048)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one Optional route value; route must declare exactly one query parameter and no path parameter
from muntin import App


def h(body: Optional[Int]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/x"](h)
