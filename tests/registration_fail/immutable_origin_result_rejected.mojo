# Must not compile: on the selected design's model, a handler whose result
# is an immutable-origin `StringSlice` other than `StaticString` (here
# `ImmutAnyOrigin`) is rejected, as production `App.get` rejects it.
# Generic `==` cannot tell such a result from `StaticString`
# (tests/registration_known_gaps/generic_equality_ignores_origin_identity.mojo),
# so the result rule is a `where` clause on each overload, which the
# compiler checks by identity at the call site (docs/ARCHITECTURE.md,
# "Registration structure decision (M3-014)"). Without the clause this
# registers as text.
# Expected diagnostic (checked by scripts/check.sh): identical(R, StringSpan[ImmStaticOrigin])
from registration_spike import Registrar


def any_origin_text() -> StringSlice[ImmutAnyOrigin]:
    return StringSlice[ImmutAnyOrigin](StaticString("any"))


def main():
    var reg = Registrar()
    reg.on["GET", "/any"](any_origin_text)
