# Must build, and is never run (scripts/check.sh builds it only). Evidence for
# docs/history/architecture-decisions.md, "Request context decision
# (M3-061)": on Mojo 1.1.0, `reflect[T].name()` is module-qualified and
# carries a type's parameters, but two distinct types can print one name:
# every origin prints as `{}`, and a function-valued parameter prints as
# `<unprintable>`, whatever the function, even when it decides the type's
# layout (`Arr` below). A request context keyed by that name could restore a
# value as a different type, a heap overflow for `Arr`. The decision
# therefore refuses, at compile time, a context value whose name contains `{`
# or `<` (string and struct values print inside `{...}` too), and keys every
# other type by its name.
#
# If this file stops building, see which assert failed. An origin or function
# assert: names now tell those types apart, so the refusal may be narrowed
# (re-measure). A marker assert: such names no longer show `{` or `<`, so the
# refusal no longer catches them; the key is unsound until it is replaced.
# The module assert: names are no longer module-qualified, so two types with
# one short name would share a key; the decision's premise is gone.

from std.reflection import reflect


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


struct Tag[text: StaticString](Movable):
    pass


struct Plain(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


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
    comptime assert reflect[Holder[ImmutAnyOrigin]].name().find("{") >= 0
    # Two functions that give the types different layouts: one name.
    comptime assert reflect[Arr[one]].name() == reflect[Arr[many]].name()
    comptime assert reflect[Arr[one]].name().find("<") >= 0
    # A string value prints inside braces.
    comptime assert reflect[Tag["x"]].name().find("{") >= 0
    # A type without such parameters: module-qualified, neither marker.
    comptime assert reflect[Plain].name() == "reflected_names_collide.Plain"
    comptime assert reflect[Plain].name().find("{") < 0
    comptime assert reflect[Plain].name().find("<") < 0
    _ = name_of(ha)
    _ = name_of(hb)
