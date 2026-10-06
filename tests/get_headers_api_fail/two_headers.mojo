# Must not compile: a get handler takes one `Headers` slot. The inverse, one
# `Headers`, registers (tests/test_get_headers.mojo). Decision:
# docs/history/architecture-decisions.md, "Typed get header access decision
# (M3-016)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes one Headers, as its last parameter
from muntin import App, Headers


def h(a: Headers, b: Headers) -> String:
    return "x"


def main():
    var app = App()
    app.get["/x"](h)
