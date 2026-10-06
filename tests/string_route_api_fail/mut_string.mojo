# Must not compile: a `String` route value is borrowed or owned (`var`); a `mut`
# one converts to no generic slot, so no `get` overload is selected, as for
# `Int`. The inverses, `name: String` and `var name: String`, register
# (tests/test_string_route_values.mojo). Decision:
# docs/history/architecture-decisions.md, "Route-value decoding and String
# route values decision (M3-018)".
# Expected diagnostic (checked by scripts/check.sh): no matching method in call to 'get'
from muntin import App


def h(mut name: String) -> String:
    return name


def main():
    var app = App()
    app.get["/x/{a}"](h)
