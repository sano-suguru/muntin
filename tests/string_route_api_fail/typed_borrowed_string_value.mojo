# Must not compile: an explicitly typed function value with a borrowed `String`
# route value converts to no generic slot, as for `Int` and `Headers`
# (tests/registration_fail/typed_value_to_owned_slot.mojo), so typed values and
# helper parameters spell it `var String`. The inverse, `def(var String) thin
# raises Never -> String`, registers (tests/test_string_route_values.mojo).
# Decision:
# docs/history/architecture-decisions.md, "Route-value decoding and String
# route values decision (M3-018)".
# Expected diagnostic (checked by scripts/check.sh): TODO: function type conversions between closures not supported yet
from muntin import App


def h(name: String) -> String:
    return name


def main():
    var app = App()
    var f: def(String) thin raises Never -> String = h
    app.get["/x/{a}"](f)
