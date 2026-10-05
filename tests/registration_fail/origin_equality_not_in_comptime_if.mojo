# Must not compile: on Mojo 1.1.0 `Origin.equals`, the one test that sees an
# origin's identity, may be used only in `where` clauses, not in a
# `comptime if`. Generic `==` drops the identity
# (tests/registration_known_gaps/generic_equality_ignores_origin_identity.mojo),
# so the selected design's text policy cannot accept `StaticString` while
# rejecting other immutable-origin `StringSlice` results
# (docs/ARCHITECTURE.md, "Registration structure decision (M3-014)"). If
# this compiles, re-measure whether the text policy can be narrowed to
# `StaticString`.
# Expected diagnostic (checked by scripts/check.sh): origin equality may only be tested in 'where' clauses


def is_static[o: Origin]() -> Bool:
    comptime if o.equals[ImmStaticOrigin]:
        return True
    return False


def main():
    print(is_static[ImmutAnyOrigin]())
