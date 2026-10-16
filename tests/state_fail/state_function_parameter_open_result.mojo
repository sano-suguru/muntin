# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": a function-valued parameter's type cannot
# leave its result's origin open, so the origin a field would take from it
# is a parameter of the struct, which prints, or `AnyOrigin`. Mojo 1.1.0
# refuses the open form before `State` sees the type.
# Expected diagnostic (checked by scripts/check.sh): is not concrete, use '[]' to bind missing parameters

from std.memory import OwnedPointer

from muntin import State


def null_view[o: Origin[mut=False]]() -> Optional[Pointer[Int, o]]:
    return None


struct Hidden[f: def() thin -> Optional[Pointer[Int, _]]](Movable):
    comptime P = type_of(Self.f())
    var p: Self.P

    def __init__(out self, var p: Self.P):
        self.p = p^


def main():
    var token = OwnedPointer(42)
    var state = State(
        Hidden[null_view[origin_of(token)]](Optional(Pointer(to=token[])))
    )
    _ = state^
