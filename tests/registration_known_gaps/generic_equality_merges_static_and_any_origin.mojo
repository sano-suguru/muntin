# Must build, and is never run (scripts/check.sh builds it only). Evidence
# for docs/ARCHITECTURE.md, "Registration structure decision (M3-014)": in a
# generic context, Mojo 1.1.0's type equality keeps an origin's mutability
# but not its identity, so `StaticString` and `StringSlice[ImmutAnyOrigin]`
# are equal in either direction, although they compare unequal outside one. So a generic result type `R` that a handler
# declares as `StringSlice[ImmutAnyOrigin]` takes the `R == StaticString`
# text branch, and the selected design accepts that result, which
# production `App.get` rejects (the third recorded change to the accepted
# set). A mutable origin stays distinct.
#
# If this file stops building, see which assert failed. The first one: the
# two types now compare equal outside a generic context; re-read the
# premise. The next two: generic equality distinguishes the origins, the
# text policy rejects the `ImmutAnyOrigin` result and the third change
# disappears. The `MutAnyOrigin` one: mutable slices merge too and the
# change widens, so re-probe the result types.


def same[A: AnyType, B: AnyType]() -> Bool:
    return A == B


def main():
    comptime assert not (StaticString == StringSlice[ImmutAnyOrigin])
    comptime assert same[StringSlice[ImmutAnyOrigin], StaticString]()
    comptime assert same[StaticString, StringSlice[ImmutAnyOrigin]]()
    comptime assert not same[StringSlice[MutAnyOrigin], StaticString]()
