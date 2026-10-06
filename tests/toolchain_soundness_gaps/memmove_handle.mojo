# Mojo 1.1.0 toolchain-wide soundness gap, outside the State guarantee
# (docs/history/architecture-decisions.md, "State storage decision
# (M3-004)"): must build, never run. If it stops building, reevaluate whether
# the sealed box and its unsafe boundary can be simplified.
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
