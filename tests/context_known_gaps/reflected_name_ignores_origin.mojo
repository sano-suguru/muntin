# Must build, and is never run (scripts/check.sh builds it only). Evidence for
# docs/history/architecture-decisions.md, "Request context decision
# (M3-058)": on Mojo 1.1.0, `reflect[T].name()` is module-qualified and
# carries a type's parameters, but prints every origin as `{}`, so two types
# that differ only in an origin share one name. A request context keyed by
# that name could restore a value made with one origin as a type with
# another; the decision therefore refuses, at compile time, a context value
# whose reflected name contains `{`, and keys every other type by its name.
#
# If this file stops building, see which assert failed. The origin asserts:
# names now tell origins apart, so the refusal may be narrowed (re-measure).
# The module assert: names are no longer module-qualified, so two types with
# one short name would share a key; the decision's premise is gone.

from std.reflection import reflect


struct Holder[o: Origin[mut=False]](Movable):
    var p: Pointer[Int, Self.o]

    def __init__(out self, ref[Self.o] x: Int):
        self.p = Pointer(to=x)


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
    # The name shows that an origin is there.
    comptime assert reflect[Holder[ImmutAnyOrigin]].name().find("{") >= 0
    # A type without an origin: module-qualified, no `{`.
    comptime assert (
        reflect[Plain].name() == "reflected_name_ignores_origin.Plain"
    )
    comptime assert reflect[Plain].name().find("{") < 0
    _ = name_of(ha)
    _ = name_of(hb)
