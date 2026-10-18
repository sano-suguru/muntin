# Must not build. Evidence for docs/history/deferrals.md, "Closing `State`'s
# `AnyOrigin` hole": generic code cannot ask whether an origin is `AnyOrigin`.
# A pointer field built with `AnyOrigin` prints `{}` like the untracked
# pointers of `List`, `String` or `ArcPointer`, and `Origin.equals`, the one
# test that tells them apart, is refused outside a `where` clause, so a check
# in `State` cannot refuse the first and admit the others.
# Expected diagnostic (checked by scripts/check.sh): origin equality may only be tested in 'where' clauses


def is_any[mut: Bool, //, o: Origin[mut=mut]]() -> Bool:
    return o.equals[AnyOrigin[mut=mut]]


def main():
    print(is_any[ImmUntrackedOrigin]())
