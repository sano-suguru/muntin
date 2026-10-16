# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": `Tuple` is refused whatever its elements. Mojo
# 1.1.0 prints a parameter pack as `<unprintable>, {}`, so its name cannot show
# whether an element borrows, and the `{}` refuses it. A struct with the same
# fields is fine. state_origin_in_tuple.mojo is the borrowing case this keeps
# out.
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type's name shows an origin or a parameter pack ({}), so it may borrow a value the App outlives: std.builtin.tuple.Tuple[<unprintable>, {}]
from muntin import State


def main():
    var state = State(Tuple(1, String("a")))
    _ = state^
