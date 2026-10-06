# Must not compile: a get handler whose only request parameter is `Headers`
# takes no route value, so its route declares no placeholder (the rule of
# `def()`); otherwise the route value would be read as a field name. The
# inverse, `def(headers: Headers)` on `/x`, registers
# (tests/test_get_headers.mojo). Decision:
# docs/history/architecture-decisions.md, "Typed get header access decision
# (M3-016)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: route declares a path parameter but the handler takes none
from muntin import App, Headers


def h(headers: Headers) -> String:
    return "x"


def main():
    var app = App()
    app.get["/x/{id}"](h)
