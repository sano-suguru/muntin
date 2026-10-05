# Must not compile: the spike's one rebind helper (`_as`) asserts type
# equality before `rebind_var`, so a layout twin that `rebind_var` alone
# accepts (tests/registration_known_gaps/rebind_var_layout_twins.mojo) is
# rejected. The selected design rebinds generic slots only through such a
# helper (docs/ARCHITECTURE.md, "Registration structure decision (M3-014)").
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a slot is rebound only to its own type
from registration_spike import _as


@fieldwise_init
struct Meters(Movable):
    var v: Int


@fieldwise_init
struct Seconds(Movable):
    var v: Int


def main():
    var s = _as[Meters, Seconds](Meters(3))
    print(s.v)
