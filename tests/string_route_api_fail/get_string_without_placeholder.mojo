# Must not compile: a `String` route value needs exactly one path or query
# placeholder, as an `Int` does; the message names `String` so that the `Int`
# text stays byte-identical. The inverse, `def(String)` on `/x/{a}`, registers
# (tests/test_string_route_values.mojo). Decision:
# docs/history/architecture-decisions.md, "Route-value decoding and String
# route values decision (M3-018)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one String parameter; route must declare exactly one path or query parameter
from muntin import App


def h(name: String) -> String:
    return name


def main():
    var app = App()
    app.get["/x"](h)
