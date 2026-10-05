# Must not compile: `rebind_var` to a type with a different layout is
# rejected at instantiation. Beside it,
# tests/registration_known_gaps/rebind_var_layout_twins.mojo builds: a
# type with the same layout is accepted. So a generic slot is rebound only
# behind a type-equality assert (exact for origin-free types)
# (docs/ARCHITECTURE.md, "Registration
# structure decision (M3-014)").
# Expected diagnostic (checked by scripts/check.sh): rebind input type
from std.builtin.rebind import rebind_var


def slot[A: Movable & Deinitable](x: Int) -> A:
    return rebind_var[A](x)


def main():
    var s = slot[String](42)
    print(s)
