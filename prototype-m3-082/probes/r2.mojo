# Probe r2 (M3-082, Mojo 1.1.0). Builds and runs (raises "x" by design):
# forwarding the refined E to a bounded helper works; json.mojo uses this
# (_read_list).
# Expect: exit 1
# Expect-output: Unhandled exception caught during execution: x
def mk[E: Movable & Deinitable](n: Int) raises -> E:
    raise Error("x")

def build[E: Movable & Deinitable]() raises:
    var l = List[E]()
    l.append(mk[E](1))
    print(len(l))

def outer[F: AnyType]() raises:
    comptime if conforms_to(F, Iterable):
        comptime E = F.IteratorType[ImmutAnyOrigin].Element
        comptime if conforms_to(E, Movable & Deinitable):
            build[E]()

def main() raises:
    outer[List[Int]]()
