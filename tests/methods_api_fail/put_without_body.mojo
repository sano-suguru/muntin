# Must not compile: `put` takes `post`'s shapes, so a typed `put` handler takes
# a body; a bodyless typed `put` is not decided. The message names the method.
# Decision: docs/history/architecture-decisions.md, "HTTP methods decision
# (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a put handler takes the request body as its last parameter
from muntin import App


def h() -> String:
    return "x"


def main():
    var app = App()
    app.put["/x"](h)
