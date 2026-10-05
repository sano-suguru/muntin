# Must not compile: an explicitly typed function value with a borrowed
# parameter (`def(Int) thin raises Never -> String`, the `raises Never`
# spelling DX section 6 documents for typed values, shown there for
# `def()`) does not convert to a generic slot,
# owned (`def(var A)`, here) or borrowed (`def(A)`, measured the same),
# although a plain `def` with that signature does
# (tests/test_spike_registration.mojo) and a value spelled
# `def(var Int) ...` does. This is the migration cost of the selected
# design (docs/ARCHITECTURE.md, "Registration structure decision
# (M3-014)"): such values and helper parameters must be respelled with
# `var`. Production `get` accepts the borrowed spelling today.
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
