# Must build, and is never run (scripts/check.sh builds it only). Evidence for
# docs/history/architecture-decisions.md, "Registration structure decision
# (M3-014)": `rebind_var` accepts a different struct with the same layout
# (`Meters` as `Seconds`) on Mojo 1.1.0. A generic slot (`var A`) therefore
# passes a parsed `Int` to the handler only through a helper that first asserts
# type equality (`A == Int`, exact for this origin-free type; `_as` in
# src/muntin/app.mojo); the rebind alone does not tell the two types apart.
# Beside it, tests/registration_fail/rebind_var_layout_mismatch.mojo pins that a
# different layout is rejected.
#
# If this file stops building, `rebind_var` checks nominal types: the
# type-equality helper is then a second check, not the only one.
from std.builtin.rebind import rebind_var


@fieldwise_init
struct Meters(Movable):
    var v: Int


@fieldwise_init
struct Seconds(Movable):
    var v: Int


def main():
    var s = rebind_var[Seconds](Meters(3))
    print(s.v)
