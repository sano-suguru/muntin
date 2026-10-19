# Must not build. Evidence for docs/history/deferrals.md, "Closing `State`'s
# `AnyOrigin` hole" (pull request #175): overloads that test the origin in a
# `where` clause, the place `Origin.equals` is allowed
# (tests/state_fail/state_any_origin_equals_outside_where.mojo), do not select
# one for an untracked origin: the constraint solver can prove neither that it
# is `AnyOrigin` nor that it is not.
# Expected diagnostic (checked by scripts/check.sh): ambiguous call to 'is_any': lacking evidence to select candidate


def is_any[
    mut: Bool, //, o: Origin[mut=mut]
]() -> Bool where o.equals[AnyOrigin[mut=mut]]:
    return True


def is_any[
    mut: Bool, //, o: Origin[mut=mut]
]() -> Bool where not o.equals[AnyOrigin[mut=mut]]:
    return False


def main():
    print(is_any[ImmUntrackedOrigin]())
