# Must not compile: An `Int` then a `String` route value on `delete`; the
# message names the method. Decision: docs/history/architecture-decisions.md,
# "HTTP methods decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a delete handler takes at most one route value
from muntin import App


def h(id: Int, name: String) -> String:
    return name


def main():
    var app = App()
    app.delete["/x/{id}"](h)
