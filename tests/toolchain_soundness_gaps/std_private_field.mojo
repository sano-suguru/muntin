# Mojo 1.1.0 toolchain-wide soundness gap: must build, never run
# (scripts/check.sh). It breaks the property M3-004 guarantees, one State
# alias replacing, mutating or destroying the payload another alias
# observes, but through a primitive that breaks the same property for
# standard-library types and existing Muntin storage, so it is outside the
# guarantee (docs/ARCHITECTURE.md, "State storage decision (M3-004)").
# If this stops building, the toolchain improved: reevaluate whether the
# sealed box and its unsafe boundary can be simplified.
#
# Primitive: a stdlib-private field reached by name (no private fields on
# 1.1.0). `ThinAllocation._ptr` is a safe `Pointer`; `List._len` and
# `OwnedPointer._inner._ptr` are reachable the same way (M2-004).
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
