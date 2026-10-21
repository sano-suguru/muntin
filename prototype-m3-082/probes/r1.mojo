# Probe r1 (M3-082, Mojo 1.1.0). Does not build: a refined E does not make
# List[E] Deinitable in the refining scope ("abandoned without being
# explicitly destroyed").
def mk[E: Movable & Deinitable](n: Int) raises -> E:
    raise Error("x")

def build[F: AnyType]() raises:
    comptime if conforms_to(F, Iterable):
        comptime E = F.IteratorType[ImmutAnyOrigin].Element
        comptime if conforms_to(E, Movable & Deinitable):
            var l = List[E]()
            l.append(mk[E](1))
            print(len(l))

def main() raises:
    build[List[Int]]()
