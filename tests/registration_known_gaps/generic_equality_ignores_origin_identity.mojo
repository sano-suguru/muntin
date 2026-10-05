# Must build, and is never run (scripts/check.sh builds it only). Evidence
# for docs/ARCHITECTURE.md, "Registration structure decision (M3-014)": in a
# generic context, Mojo 1.1.0's type equality keeps an origin's mutability
# but not its identity. `StaticString` (`StringSlice[ImmStaticOrigin]`)
# equals `StringSlice` with `ImmutAnyOrigin`, `ImmUntrackedOrigin` or a
# local's origin made immutable, in either direction. Outside a generic
# context the first two compare unequal to it; a local's origin compares
# equal even there. A mutable origin stays distinct.
# So the selected design's text policy (`R == StaticString`) accepts every
# immutable-origin `StringSlice` result that a handler can express and
# bind; production `App.get` accepts only `StaticString` (the third
# recorded change to the accepted set).
#
# If this file stops building, see which assert failed. A non-generic
# inequality: the types now compare equal outside a generic context;
# re-read the premise. A generic equality: generic equality now tells that
# origin apart, so the text policy rejects it and the third change shrinks
# (re-measure, re-pin the spike tests). The `MutAnyOrigin` one: mutable
# slices merge too and the change widens, so re-probe the result types.


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
