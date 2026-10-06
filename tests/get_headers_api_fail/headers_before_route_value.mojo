# Must not compile: a `Headers` slot is a get handler's last parameter, after
# the route value, never before it (positional binding: its raw index is its
# position, since only a route value precedes it). The inverse, `def(id: Int,
# headers: Headers)`, registers (tests/test_get_headers.mojo). Decision:
# docs/history/architecture-decisions.md, "Typed get header access decision
# (M3-016)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes one Headers, as its last parameter
from muntin import App, Headers


def h(headers: Headers, id: Int) -> String:
    return "x"


def main():
    var app = App()
    app.get["/x/{id}"](h)
