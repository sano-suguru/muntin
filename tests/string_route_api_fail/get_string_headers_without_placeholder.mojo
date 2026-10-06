# Must not compile: `def(String, Headers)` follows the placeholder rule of its
# `String` route value, with the `String` message. The inverse, on a route with
# one placeholder, registers (tests/test_string_route_values.mojo). Decision:
# docs/history/architecture-decisions.md, "Route-value decoding and String
# route values decision (M3-018)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one String parameter; route must declare exactly one path or query parameter
from muntin import App, Headers


def h(name: String, headers: Headers) -> String:
    return name


def main():
    var app = App()
    app.get["/x"](h)
