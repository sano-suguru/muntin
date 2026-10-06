# Must not compile: the `String` kind is exact type equality, so a
# `StringSlice` of any origin is no route value; it is a parameter of no kind
# (static_string_is_no_route_value.mojo pins the static origin). Decision:
# docs/history/architecture-decisions.md, "Route-value decoding and String
# route values decision (M3-018)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler's parameter is an Int or String route value, the request Headers or, for a raw handler, the Request
from muntin import App


def h(name: StringSlice[ImmutAnyOrigin]) -> String:
    return String(name)


def main():
    var app = App()
    app.get["/x/{a}"](h)
