# Must not compile: on Mojo 1.1.0 `Origin.equals` may be used only in
# `where` clauses, not in a `comptime if`, and generic `==` drops an
# origin's identity
# (tests/registration_known_gaps/generic_equality_ignores_origin_identity.mojo).
# So no check inside a generic body can accept `StaticString` while
# rejecting other immutable-origin `StringSlice` results; the selected
# design states its result rule as a `where` clause on each overload
# (docs/ARCHITECTURE.md, "Registration structure decision (M3-014)"). If
# this compiles, the rule could move into the body with the other rules
# and keep their Muntin message.
# Expected diagnostic (checked by scripts/check.sh): origin equality may only be tested in 'where' clauses


def is_static[o: Origin]() -> Bool:
    comptime if o.equals[ImmStaticOrigin]:
        return True
    return False


def main():
    print(is_static[ImmutAnyOrigin]())
