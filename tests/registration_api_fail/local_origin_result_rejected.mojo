# Must not compile: a handler whose result is a `StringSlice` with a
# local's immutable origin (`origin_text[ImmOrigin(origin_of(s))]`) is
# rejected by the result `where` clause, but not as `no matching method`:
# the compiler cannot prove the clause for this candidate and reports
# `invalid call ... lacking evidence to prove correctness`
# (docs/ARCHITECTURE.md, "Registration structure decision (M3-014)", which
# measured this on the model). Before M3-015 the same registration was
# `no matching method in call to 'get'`, with the result rejected by the
# `ToResponse` bound.
# Expected diagnostic (checked by scripts/check.sh): invalid call to 'get': lacking evidence to prove correctness
from muntin import App


def origin_text[o: ImmOrigin]() -> StringSlice[o]:
    return StringSlice[o]()


def main():
    var s = String("local")
    var app = App()
    app.get["/x"](origin_text[ImmOrigin(origin_of(s))])
    _ = s^
