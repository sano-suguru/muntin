# Must not compile: an explicitly typed function value whose `Int` route
# value is borrowed (`def(Int) thin raises Never -> String`) converts to no
# generic slot, so it no longer registers on `App.get` (the narrowed edge of
# M3-015). Before M3-015 this built, and the `def(var Int)` spelling was
# `no matching method in call to 'get'`; now the `var` spelling registers
# (tests/test_registration.mojo). A plain `def` with a borrowed `Int` is
# unaffected. Toolchain pin: tests/registration_fail/
# typed_value_to_owned_slot.mojo.
# Expected diagnostic (checked by scripts/check.sh): TODO: function type conversions between closures not supported yet
from muntin import App


def by_id(id: Int) -> String:
    return String(id)


def main():
    var app = App()
    var f: def(Int) thin raises Never -> String = by_id
    app.get["/users/{id}"](f)
