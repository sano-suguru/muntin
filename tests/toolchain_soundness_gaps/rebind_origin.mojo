# Mojo 1.1.0 toolchain-wide soundness gap, outside the State guarantee
# (docs/history/architecture-decisions.md, "State storage decision
# (M3-004)"): must build, never run. If it stops building, reevaluate whether
# the sealed box and its unsafe boundary can be simplified.
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
