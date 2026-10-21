# Probe e4 (M3-082, Mojo 1.1.0). Builds and runs: the element type of
# List[MoveOnly], Optional[MoveOnly] and Dict[String, Int]; `F == List[E]` is
# true for List, false for Dict and for a user struct named List.
@fieldwise_init
struct MoveOnly(Movable):
    var x: Int

struct List:
    var x: Int

def probe[FT: AnyType]():
    comptime if conforms_to(FT, Iterable):
        comptime E = FT.IteratorType[ImmutAnyOrigin].Element
        print(reflect[FT].name(), "iterable, element", reflect[E].name(), reflect[FT].base_name())
        comptime if conforms_to(E, Copyable):
            print("  equals std List[E]:", FT == std.collections.List[E])
    else:
        print("not iterable", reflect[FT].name())


def main() raises:
    probe[std.collections.List[MoveOnly]]()
    probe[std.collections.List[Int]]()
    probe[Optional[MoveOnly]]()
    probe[Dict[String, Int]]()
    probe[List]()
