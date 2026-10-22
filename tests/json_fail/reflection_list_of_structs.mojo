# Must not compile (M3-008): this reflection-derived encoder cannot walk a
# `List[E]` field whose element is an application struct: through
# `downcast` and iteration the element is an `AnyType` value that cannot be
# destroyed. M3-082 reaches the element type without `__extension` instead
# (`comptime if conforms_to(T, Iterable)`, then `T == List[E]`); this pins
# only the approach above.
# Expected diagnostic (checked by scripts/check.sh): abandoned without being explicitly destroyed: unhandled explicitly destroyed type 'AnyType'
from std.builtin.rebind import downcast


def enc[T: AnyType](mut out: String, value: T):
    comptime if T == Int:
        out += String(rebind[Int](value))
    elif conforms_to(T, Iterable):
        ref it = rebind[downcast[T, Iterable]](value)
        for ref e in it:
            enc(out, e)


@fieldwise_init
struct Address(Copyable):
    var zip: Int


def main():
    var out = String()
    enc(out, [Address(1)])
