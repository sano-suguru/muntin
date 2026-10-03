# Known gap (M3-004): must build, never run (scripts/check.sh). Where the
# sealed box's seal ends: the stdlib's private `ThinAllocation._ptr` is a
# safe `Pointer` reachable by name (Mojo 1.1.0 has no private fields), so
# code holding a second handle can replace the shared value without writing
# `unsafe`, and `r` then reads a dropped value. This is the reach M2-004
# recorded for `_Erased` and for the stdlib's own types (`List._len`,
# `OwnedPointer._inner._ptr`, `app._routes._len`). If this stops building,
# the toolchain sealed std-private fields: revisit docs/ARCHITECTURE.md
# "State storage decision (M3-004)".
from std.memory import OwnedPointer
from state_storage_spike import State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def main():
    var a = State(Db(1))
    var b = a.copy()
    ref r = a[]
    b._shared._header._ptr[].value = OwnedPointer(Db(2))
    print(r.n)
