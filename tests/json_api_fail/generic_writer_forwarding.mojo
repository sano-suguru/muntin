# Must not compile (M3-075): on Mojo 1.1.0 a generic overload cannot forward
# to the overload of its parameter's type. Here `value[T](Optional[T])`
# calls `self.value(x)` with `x: T`; the call resolves to the generic
# `Optional` overload itself (by `Optional`'s implicit conversion from `T`),
# not to `value(Int)` at instantiation, so `JsonWriter` declares each
# `Optional`/`List` combination as its own overload. Building alone is not
# the signal: with `T: ImplicitlyCopyable` this builds and calls itself
# forever. If it builds and prints `int`, the combinations can collapse into
# generic overloads.
# Expected diagnostic (checked by scripts/check.sh): value of type 'T' cannot be implicitly copied, it does not conform to 'ImplicitlyCopyable'
struct Writer:
    var out: String

    def __init__(out self):
        self.out = String()

    def value(mut self, v: Int):
        self.out += "int"

    def value[T: Copyable](mut self, v: Optional[T]):
        if v:
            ref x = v.value()
            self.value(x)
        else:
            self.out += "null"


def main():
    var w = Writer()
    w.value(Optional[Int](1))
    print(w.out)
