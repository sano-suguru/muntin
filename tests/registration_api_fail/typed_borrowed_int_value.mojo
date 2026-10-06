# Must not compile: an explicitly typed function value whose `Int` route value
# is borrowed (`def(Int) thin raises Never -> String`) converts to no generic
# slot, so it does not register on `App.get` (M3-014, edge 3); the `var`
# spelling registers (tests/test_registration.mojo). A plain `def` with a
# borrowed `Int` is unaffected. Toolchain pin: tests/registration_fail/
# typed_value_to_owned_slot.mojo.
# Expected diagnostic (checked by scripts/check.sh): TODO: function type conversions between closures not supported yet
from muntin import App


def by_id(id: Int) -> String:
    return String(id)


def main():
    var app = App()
    var f: def(Int) thin raises Never -> String = by_id
    app.get["/users/{id}"](f)
