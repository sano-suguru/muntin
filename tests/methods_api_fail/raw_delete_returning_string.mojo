# Must not compile: A `Request` handler on `delete` that does not return
# `Response` breaks the raw rule; the message names the method. Decision:
# docs/history/architecture-decisions.md, "HTTP methods decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a raw delete handler takes only the Request and returns Response
from muntin import App, Request


def h(req: Request) -> String:
    return req.path


def main():
    var app = App()
    app.delete["/x"](h)
