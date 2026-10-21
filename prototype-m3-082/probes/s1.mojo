# Probe s1 (M3-082, Mojo 1.1.0). Does not build: a struct-scope `comptime
# assert` is refused ("must be inside a function").
# Expect: build fails
# Expect-output: 'comptime assert' must be inside a function
def _ok[T: AnyType]() -> Bool:
    comptime types = reflect[T].field_types()
    comptime for i in range(reflect[T].field_count()):
        comptime if types[i] != Int:
            return False
    return True


trait Marker:
    comptime _check: Bool = _ok[Self]()


@fieldwise_init
struct Counts(Marker):
    var total: Int
    var by_name: Dict[String, Int]
    comptime assert _ok[Self](), "Counts: unsupported field"


def main():
    pass
