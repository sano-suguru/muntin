# Must not compile: an `Int` then a `String` route value on `delete` with one
# placeholder; two values need exactly two. Decisions:
# docs/history/architecture-decisions.md, "HTTP methods decision (M3-020)" and
# "Several route values decision (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes two route values; route must declare exactly two path or query parameters
from muntin import App


def h(id: Int, name: String) -> String:
    return name


def main():
    var app = App()
    app.delete["/x/{id}"](h)
