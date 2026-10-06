# Known gap (M3-004): must build, never run (scripts/check.sh). Rejected
# candidate B': a `State` holding an `ArcPointer[OwnedPointer[S]]` field.
# `ArcPointer.__getitem__` returns a mutable reference through any handle, so a
# second handle replaces the shared `OwnedPointer` with public std API alone,
# and `r` reads a dropped value. The sealed box rejects the same line
# (state_storage_fail/alias_payload_swap.mojo). If this stops building,
# `ArcPointer` no longer hands out mutable references through shared handles:
# revisit docs/history/architecture-decisions.md "State storage decision
# (M3-004)".
from std.memory import ArcPointer, OwnedPointer


struct ArcState[S: Movable & Deinitable](Copyable, Movable):
    var _shared: ArcPointer[OwnedPointer[Self.S]]

    def __init__(out self, var value: Self.S):
        self._shared = ArcPointer(OwnedPointer(value^))

    def __getitem__(
        self,
    ) -> ref[ImmOrigin(origin_of(self._shared[][]))] Self.S:
        return self._shared[][]


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def main():
    var a = ArcState(Db(1))
    var b = a.copy()
    ref r = a[]
    b._shared[] = OwnedPointer(Db(2))
    print(r.n)
