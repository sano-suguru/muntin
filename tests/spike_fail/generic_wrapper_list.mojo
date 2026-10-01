# Must not compile: a generic wrapper is one concrete type per parameter, so
# one List cannot hold wrappers of two handler types.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'Wrap[B]' to 'Wrap[A]'


trait Invoke(Copyable, Deinitable):
    def invoke(self, x: Int) -> String:
        ...


@fieldwise_init
struct A(Invoke):
    def invoke(self, x: Int) -> String:
        return "a"


@fieldwise_init
struct B(Invoke):
    def invoke(self, x: Int) -> String:
        return "b"


@fieldwise_init
struct Wrap[T: Invoke](Copyable):
    var t: Self.T


def main():
    var l = List[Wrap[A]]()
    l.append(Wrap(A()))
    l.append(Wrap(B()))
