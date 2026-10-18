# Must not build. Evidence for docs/history/deferrals.md, "Closing `State`'s
# `AnyOrigin` hole": in generic code, the comparison of two types ignores
# their origins, so a check in `State` cannot tell a pointer field built with
# `AnyOrigin` from the untracked pointer an owning container holds by
# comparing the field's type with one it builds.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: generic code compares Pointer[Int, ImmutAnyOrigin] and Pointer[Int, ImmUntrackedOrigin] as one type


def require_distinct[A: AnyType, B: AnyType]():
    comptime assert not (A == B), (
        "generic code compares Pointer[Int, ImmutAnyOrigin] and Pointer[Int,"
        " ImmUntrackedOrigin] as one type"
    )


def main():
    require_distinct[
        Pointer[Int, ImmutAnyOrigin], Pointer[Int, ImmUntrackedOrigin]
    ]()
