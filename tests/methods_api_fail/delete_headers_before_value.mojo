# Must not compile: `Headers` before the route value on `delete`; the message
# names the method. Decision: docs/history/architecture-decisions.md, "HTTP
# methods decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a delete handler takes one Headers, as its last parameter
from muntin import App, Headers


def h(headers: Headers, id: Int) -> String:
    return String(id)


def main():
    var app = App()
    app.delete["/x/{id}"](h)
