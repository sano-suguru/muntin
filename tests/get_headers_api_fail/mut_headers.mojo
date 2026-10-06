# Must not compile: a `Headers` parameter is borrowed or owned (`var`); a
# `mut` one converts to no generic slot, so no `get` overload is selected.
# The inverses, `headers: Headers` and `var headers: Headers`, register
# (tests/test_get_headers.mojo). Decision:
# docs/history/architecture-decisions.md, "Typed get header access decision
# (M3-016)".
# Expected diagnostic (checked by scripts/check.sh): no matching method in call to 'get'
from muntin import App, Headers


def h(mut headers: Headers) -> String:
    return "x"


def main():
    var app = App()
    app.get["/x"](h)
