# Must build, and is never run (scripts/check.sh builds it only). Evidence
# for docs/ARCHITECTURE.md, "Registration structure decision (M3-014)": in a
# generic context, Mojo 1.1.0's type equality does not tell `StaticString`
# from `StringSlice[ImmutAnyOrigin]`, in either direction, although the two
# compare unequal outside one. So a generic result type `R` that a handler
# declares as `StringSlice[ImmutAnyOrigin]` takes the `R == StaticString`
# text branch, and the selected design accepts that result, which
# production `App.get` rejects (the third recorded change to the accepted
# set). A mutable origin stays distinct.
#
# If this file stops building, generic equality distinguishes the origins:
# the text policy then rejects the `ImmutAnyOrigin` result, and the third
# change disappears.


def same[A: AnyType, B: AnyType]() -> Bool:
    return A == B


def main():
    comptime assert same[StringSlice[ImmutAnyOrigin], StaticString]()
    comptime assert same[StaticString, StringSlice[ImmutAnyOrigin]]()
    comptime assert not same[StringSlice[MutAnyOrigin], StaticString]()
