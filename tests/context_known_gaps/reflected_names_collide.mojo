# Must build, and is never run (scripts/check.sh builds it only). Evidence for
# docs/history/architecture-decisions.md, "Request context decision
# (M3-063)", which leaves how context values are stored undecided because
# Mojo 1.1.0 offers no documented type identity:
# - `reflect[T].name()` prints distinct types alike: every origin as `{}`,
#   and a function-valued parameter as `<unprintable>` even when it decides
#   the type's layout (`Arr`). Restoring a value under such a name overflowed
#   the heap under AddressSanitizer (pull request #113).
# - `get_linkage_name` of a function specialized on the type tells the `Arr`s
#   apart but not two origins, and is a symbol name, not a documented
#   identity.
# A function's address is no identity either: specializations with equal
# bodies share one address (measured in pull request #113; not pinned here,
# since this file never runs).
#
# If this file stops building, a candidate identity changed: re-measure it
# before the context storage item relies on it.

from std.reflection import reflect
from std.reflection.type_info import get_linkage_name


struct Holder[o: Origin[mut=False]](Movable):
    var p: Pointer[Int, Self.o]

    def __init__(out self, ref[Self.o] x: Int):
        self.p = Pointer(to=x)


def one() -> Int:
    return 1


def many() -> Int:
    return 64


struct Arr[f: def() thin -> Int](Movable):
    var data: SIMD[DType.int64, Self.f()]

    def __init__(out self):
        self.data = SIMD[DType.int64, Self.f()](7)


def token[T: AnyType]():
    pass


def name_of[T: AnyType](x: T) -> StaticString:
    return reflect[T].name()


def main():
    var a = 1
    var b = 2
    var ha = Holder(a)
    var hb = Holder(b)
    # Two local origins, and a local's against `ImmutAnyOrigin`: one name.
    comptime assert reflect[type_of(ha)].name() == reflect[type_of(hb)].name()
    comptime assert (
        reflect[type_of(ha)].name() == reflect[Holder[ImmutAnyOrigin]].name()
    )
    # Two functions that give the types different layouts: one name.
    comptime assert reflect[Arr[one]].name() == reflect[Arr[many]].name()
    # Linkage names: the two `Arr`s apart, the origins still alike.
    comptime assert (
        get_linkage_name[token[Arr[one]]]()
        != get_linkage_name[token[Arr[many]]]()
    )
    comptime assert (
        get_linkage_name[token[type_of(ha)]]()
        == get_linkage_name[token[type_of(hb)]]()
    )
    comptime assert (
        get_linkage_name[token[type_of(ha)]]()
        == get_linkage_name[token[Holder[ImmutAnyOrigin]]]()
    )
    _ = name_of(ha)
    _ = name_of(hb)
