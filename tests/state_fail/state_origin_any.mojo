# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": a type instantiated with `AnyOrigin` is refused too;
# what that origin allows outside `State` is the toolchain-wide hole of
# tests/registration_known_gaps/safe_dangling_any_origin_slice.mojo.
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type has an origin parameter (printed {}) or one Mojo cannot print, so it may borrow a value the App outlives: state_origin_any.Holder[{}, {}]
from muntin import State


struct Holder[o: Origin[mut=False]](Movable):
    var p: Optional[Pointer[Int, Self.o]]

    def __init__(out self):
        self.p = None


def main():
    var state = State(Holder[ImmutAnyOrigin]())
    _ = state^
