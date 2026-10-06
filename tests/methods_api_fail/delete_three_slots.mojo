# Must not compile: three request slots, no `State` and no state argument match
# none of `delete`'s six overloads, so the compiler's own diagnostic names the
# method, as for `get` and `post`. Decision:
# docs/history/architecture-decisions.md, "HTTP methods decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): no matching method in call to 'delete'
from muntin import App, Headers


def h(a: Int, b: Int, headers: Headers) -> String:
    return "x"


def main():
    var app = App()
    app.delete["/x/{a}"](h)
