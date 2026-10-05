# Must not compile: an explicitly typed function value with a borrowed
# `Headers` parameter converts to no generic slot, as for an `Int` route
# value (tests/registration_fail/typed_value_to_owned_slot.mojo), so typed
# values and helper parameters spell it `var Headers`. The inverse,
# `def(var Headers) thin raises Never -> String`, registers
# (tests/test_spike_get_headers.mojo). Decision: docs/ARCHITECTURE.md,
# "Typed get header access decision (M3-016)".
# Expected diagnostic (checked by scripts/check.sh): TODO: function type conversions between closures not supported yet
from muntin import App, Headers

from get_headers_spike import get


def h(headers: Headers) -> String:
    return "x"


def main():
    var app = App()
    var f: def(Headers) thin raises Never -> String = h
    get["/x"](app, f)
