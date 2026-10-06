# Must not compile: A typed `patch` handler takes a body (`post`'s shapes); a
# bodyless one is not decided. The message names the method. Decision:
# docs/history/architecture-decisions.md, "HTTP methods decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a patch handler takes the request body as its last parameter
from muntin import App


def h() -> String:
    return "x"


def main():
    var app = App()
    app.patch["/x"](h)
