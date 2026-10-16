# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": a mutable origin is refused like an immutable one.
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type has an origin parameter (printed {}) or one Mojo cannot print, so it may borrow a value the App outlives: state_origin_mut.Counter[{}, {}]

from std.memory import OwnedPointer

from muntin import State


struct Counter[o: Origin[mut=True]](Movable):
    var p: Pointer[Int, Self.o]

    def __init__(out self, ref[Self.o] x: Int):
        self.p = Pointer(to=x)


def main():
    var token = OwnedPointer(42)
    var state = State(Counter(token[]))
    _ = state^
