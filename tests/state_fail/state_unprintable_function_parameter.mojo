# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": a function-valued parameter prints as
# `<unprintable>` and no `{}`, so only that half of the rule refuses it
# (`Tuple`'s name shows both, state_unprintable_tuple.mojo). The name cannot
# show what such a parameter holds, so it is refused whatever it is.
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type has an origin parameter (printed {}) or one Mojo cannot print, so it may borrow a value the App outlives: state_unprintable_function_parameter.Sized[<unprintable>]
from muntin import State


def four() -> Int:
    return 4


struct Sized[f: def() thin -> Int](Movable):
    var data: SIMD[DType.int64, Self.f()]

    def __init__(out self):
        self.data = SIMD[DType.int64, Self.f()](7)


def main():
    var state = State(Sized[four]())
    _ = state^
