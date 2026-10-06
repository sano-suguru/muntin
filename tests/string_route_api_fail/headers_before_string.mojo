# Must not compile: a `Headers` slot is a get handler's last parameter, after a
# `String` route value as after an `Int` one. The inverse, `def(String,
# Headers)`, registers (tests/test_string_route_values.mojo). Decision:
# docs/history/architecture-decisions.md, "Route-value decoding and String
# route values decision (M3-018)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes one Headers, as its last parameter
from muntin import App, Headers


def h(headers: Headers, name: String) -> String:
    return name


def main():
    var app = App()
    app.get["/x/{s}"](h)
