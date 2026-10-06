# Known gap (M3-004): must build, never run (scripts/check.sh). Rejected
# candidate B: M3-001's `State`, an `ArcPointer[S]` field (the retained spike's,
# tests/state_spike.mojo). A second handle mutates the shared value through
# `ArcPointer.__getitem__`, freeing the list a reference from the first handle
# points into, with public std API alone. The sealed box rejects the same
# mutation (state_storage_fail/alias_value_mutation.mojo). If this stops
# building, revisit docs/history/architecture-decisions.md "State storage
# decision (M3-004)".
from state_spike import State


struct Users(Movable):
    var names: List[String]

    def __init__(out self, var names: List[String]):
        self.names = names^


def main():
    var names = List[String]()
    names.append("a string long enough to live on the heap ................")
    var a = State(Users(names^))
    var b = a.copy()
    ref first = a[].names[0]
    b._shared[].names.clear()
    print(first)
