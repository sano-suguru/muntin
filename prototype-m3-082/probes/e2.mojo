# Probe e2 (M3-082, Mojo 1.1.0). Builds and runs: inside `comptime if
# conforms_to(F, Iterable)`, `F.IteratorType[ImmutAnyOrigin].Element` names
# the element of List[Address], List[Int] and Optional[Address].
# Expect: exit 0
# Expect-output: element e2\.Address\n.*element SIMD\[DType\.int, 1\]\n.*element e2\.Address
from muntin import JsonWriter, ToJson


@fieldwise_init
struct Address(Copyable, ToJson):
    var zip: Int

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("zip", self.zip)
        out.end_object()


def probe[FT: AnyType]():
    comptime if conforms_to(FT, Iterable):
        comptime E = FT.IteratorType[ImmutAnyOrigin].Element
        print("iterable, element", reflect[E].name())
    else:
        print("not iterable", reflect[FT].name())


def main() raises:
    probe[List[Address]]()
    probe[List[Int]]()
    probe[Optional[Address]]()
