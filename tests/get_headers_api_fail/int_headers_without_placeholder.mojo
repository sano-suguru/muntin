# Must not compile: a get handler taking an `Int` route value, then `Headers`,
# needs exactly one placeholder (the rule of `def(Int)`); otherwise a field
# name would be parsed as the route value. The inverse, on `/x/{id}`,
# registers (tests/test_get_headers.mojo). Decision:
# docs/history/architecture-decisions.md, "Typed get header access decision
# (M3-016)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one Int parameter; route must declare exactly one path or query parameter
from muntin import App, Headers


def h(id: Int, headers: Headers) -> String:
    return "x"


def main():
    var app = App()
    app.get["/x"](h)
