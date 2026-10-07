# Must not compile: two route values and `Headers` on `delete` with one
# placeholder select `delete`'s slot-arity-3 overload, which reports the
# placeholder count. Decisions: docs/history/architecture-decisions.md, "HTTP
# methods decision (M3-020)" and "Several route values decision (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes two route values; route must declare exactly two path or query parameters
from muntin import App, Headers


def h(a: Int, b: Int, headers: Headers) -> String:
    return "x"


def main():
    var app = App()
    app.delete["/x/{a}"](h)
