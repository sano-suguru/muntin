# Mojo 1.1.0 toolchain-wide soundness gap: must build, never run
# (scripts/check.sh). It breaks the property M3-004 guarantees, one State
# alias replacing, mutating or destroying the payload another alias
# observes, but through a primitive that breaks the same property for
# standard-library types and existing Muntin storage, so it is outside the
# guarantee (docs/ARCHITECTURE.md, "State storage decision (M3-004)").
# If this stops building, the toolchain improved: reevaluate whether the
# sealed box and its unsafe boundary can be simplified.
#
# Primitive: `rebind` launders an immutable origin into `MutAnyOrigin`.
# Through the public `state[]` alone, a second alias frees the list a
# reference from the first points into; the same works on a borrowed std
# `List`.
from std.memory import Pointer
from state_storage_spike import State


struct Users(Movable):
    var names: List[String]

    def __init__(out self, var names: List[String]):
        self.names = names^


def through_state():
    var names = List[String]()
    names.append("a string long enough to live on the heap ..........")
    var a = State(Users(names^))
    var b = a.copy()
    ref first = a[].names[0]
    var p = rebind[Pointer[Users, MutAnyOrigin]](Pointer(to=b[]))
    p[].names.clear()
    print(first)


def through_list(names: List[String]):
    ref first = names[0]
    var p = rebind[Pointer[List[String], MutAnyOrigin]](Pointer(to=names))
    p[].clear()
    print(first)


def main():
    through_state()
    through_list(["another heap string ................................"])
