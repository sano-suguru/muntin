# Must build, and is never run (scripts/check.sh builds it only). Evidence
# for docs/ARCHITECTURE.md, "Registration structure decision (M3-014)": in a
# generic context, Mojo 1.1.0's type equality keeps an origin's mutability
# but not its identity. `StaticString` (`StringSlice[ImmStaticOrigin]`)
# equals `StringSlice` with `ImmutAnyOrigin`, `ImmUntrackedOrigin` or a
# local's origin made immutable, in either direction. Outside a generic
# context the first two compare unequal to it; a local's origin compares
# equal even there. A mutable origin stays distinct.
# So a text-result check written as `R == StaticString` inside a generic
# body would accept every immutable-origin `StringSlice` a handler can
# express and bind; production `App.get` accepts only `StaticString`. The
# selected design therefore states its result rule as a `where` clause,
# which the compiler checks by identity at the call site
# (tests/registration_api_fail/immutable_origin_result_*.mojo).
#
# If this file stops building, see which assert failed. A non-generic
# inequality: the types now compare equal outside a generic context; the
# direct equality for a local's origin: a local's origin is now told apart
# directly. Either way, re-read the premise. A generic equality: generic
# equality now tells that origin apart, so a body-level check could replace
# the `where` clause (re-measure). The `MutAnyOrigin` one: mutable slices
# merge too; re-probe the result types.


def same[A: AnyType, B: AnyType]() -> Bool:
    return A == B


def main():
    comptime assert not (StaticString == StringSlice[ImmutAnyOrigin])
    comptime assert not (StaticString == StringSlice[ImmUntrackedOrigin])
    comptime assert same[StringSlice[ImmutAnyOrigin], StaticString]()
    comptime assert same[StaticString, StringSlice[ImmutAnyOrigin]]()
    comptime assert same[StringSlice[ImmUntrackedOrigin], StaticString]()
    comptime assert same[StaticString, StringSlice[ImmUntrackedOrigin]]()
    comptime assert not same[StringSlice[MutAnyOrigin], StaticString]()
    var s = String("local")
    # For a local's origin even a direct comparison reports equal, though
    # production's overloads still reject such a result type.
    comptime assert StaticString == StringSlice[ImmOrigin(origin_of(s))]
    comptime assert same[StringSlice[ImmOrigin(origin_of(s))], StaticString]()
    _ = s^
