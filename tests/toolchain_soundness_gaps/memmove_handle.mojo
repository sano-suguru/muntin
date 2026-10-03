# Mojo 1.1.0 toolchain-wide soundness gap: must build, never run
# (scripts/check.sh). It breaks the property M3-004 guarantees, one State
# alias replacing, mutating or destroying the payload another alias
# observes, but through a primitive that breaks the same property for
# standard-library types and existing Muntin storage, so it is outside the
# guarantee (docs/ARCHITECTURE.md, "State storage decision (M3-004)").
# If this stops building, the toolchain improved: reevaluate whether the
# sealed box and its unsafe boundary can be simplified.
#
# Primitive: the deprecated public `memmove` bit-copies one handle over
# another (a deprecation warning only, so this directory builds without
# --Werror). The count is not incremented, and the value `r` reads is
# dropped while `r` lives (M2-004 recorded the same reach for `_Erased`).
from std.memory import Pointer, memmove
from state_storage_spike import State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def overwrite(a: State[Db]):
    var c = a.copy()
    var b = State(Db(2))
    memmove(dest=Pointer(to=b), src=Pointer(to=c), count=1)


def main():
    var a = State(Db(1))
    ref r = a[]
    overwrite(a)
    print(r.n)
