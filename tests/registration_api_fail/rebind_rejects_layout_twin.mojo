# Must not compile: production's one rebind helper (`_as`) asserts type
# equality before rebinding, so a layout twin that the rebind alone accepts
# (tests/registration_known_gaps/rebind_var_layout_twins.mojo) is rejected
# (docs/ARCHITECTURE.md, "Registration structure decision (M3-014)").
# Expected diagnostic (checked by scripts/check.sh): constraint failed: rebind requires generic type equality
from muntin.app import _as


@fieldwise_init
struct Meters(Movable):
    var v: Int


@fieldwise_init
struct Seconds(Movable):
    var v: Int


def main():
    var s = _as[Meters, Seconds](Meters(3))
    print(s.v)
