# Must not compile: an explicitly typed function value with a borrowed
# parameter (`def(Int) thin raises Never -> String`, the `raises Never`
# spelling DX section 6 documents for typed values, shown there for `def()`)
# does not convert to a generic slot, owned (`def(var A)`, here) or borrowed
# (`def(A)`, measured the same), although a plain `def` with that signature
# does and a value spelled `def(var Int) ...` does
# (tests/test_registration.mojo). This is the migration cost of the selected
# design (docs/ARCHITECTURE.md, "Registration structure decision (M3-014)"):
# such values and helper parameters must spell a borrowed `Int` route value
# with `var` (a leading `State[S]` is not a slot and keeps its spelling; a
# borrowed body or `Request` already failed before). Production `get` rejects
# the borrowed spelling since M3-015
# (tests/registration_api_fail/typed_borrowed_int_value.mojo).
# Expected diagnostic (checked by scripts/check.sh): function type conversions between closures not supported yet


struct Registrar:
    def __init__(out self):
        pass

    def on[
        A: Movable & Deinitable, E: Deinitable, R: Movable & Deinitable, //
    ](mut self, handler: def(var A) thin raises E -> R):
        pass


def by_id(id: Int) -> String:
    return String(id)


def main():
    var reg = Registrar()
    var f: def(Int) thin raises Never -> String = by_id
    reg.on(f)
